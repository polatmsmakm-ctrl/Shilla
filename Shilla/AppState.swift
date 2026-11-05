import SwiftUI
import UserNotifications
import Photos
import WebRTC
import CryptoKit

struct FileItem: Sendable {
    let url: URL
    let rel: String
    let size: Int64
}

/// تقدّم دفعة ملفات تنرسل بالتوازي
@MainActor
final class BatchTracker {
    var base: Int64 = 0
    var done = 0
    var live: [Int: Int64] = [:]
    var total: Int64 { base + live.values.reduce(0, +) }
}

/// غلاف بسيط حتى نمرر القاموس بين المهام
struct SendableMeta: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}

@MainActor
final class AppState: ObservableObject {
    // الهوية والإعدادات
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: "username") } }
    @Published var relayURL: String { didSet { UserDefaults.standard.set(relayURL, forKey: "relayURL") } }
    @Published var turnURL: String { didSet { UserDefaults.standard.set(turnURL, forKey: "turnURL") } }
    @Published var turnUser: String { didSet { UserDefaults.standard.set(turnUser, forKey: "turnUser") } }
    @Published var turnPass: String { didSet { UserDefaults.standard.set(turnPass, forKey: "turnPass") } }
    @Published var keepAlive: Bool {
        didSet { UserDefaults.standard.set(keepAlive, forKey: "keepAlive"); KeepAlive.shared.set(keepAlive) }
    }

    // الحالة
    @Published var friends: [Friend] = []
    @Published var messages: [ChatMessage] = []
    @Published var progress: [String: TransferState] = [:]
    @Published var online: [String: Bool] = [:]
    @Published var linkStates: [String: String] = [:]
    /// كم حارة اتصال شغالة مع كل صديق (من 4)
    @Published var lanes: [String: Int] = [:]
    @Published var lastRead: [String: Double] = [:]
    @Published var mqttUp = false
    @Published var toast: String?
    var activeChat: String?
    /// البرنامج مخفي ورا اللعبة: ما نعلّم الرسائل كمقروءة
    var locked = true

    private let mqtt = MQTTClient()
    private var links: [String: PeerLink] = [:]
    private var saveTask: Task<Void, Never>?
    private let deviceId: String

    private var lastSample: [String: (Date, Int64)] = [:]
    private var lastPublish: [String: Date] = [:]
    private var recvBase: [String: Int64] = [:]
    private var recvCount: [String: Int] = [:]
    /// بايتات الملفات اللي جاري استقبالها الحين لكل دفعة (تنرسل بالتوازي)
    private var recvLive: [String: [String: Int64]] = [:]

    var isSetup: Bool { !username.isEmpty }

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "did") { deviceId = id } else {
            deviceId = String(UUID().uuidString.prefix(8)).lowercased()
            d.set(deviceId, forKey: "did")
        }
        username = d.string(forKey: "username") ?? ""
        relayURL = d.string(forKey: "relayURL") ?? ""
        turnURL = d.string(forKey: "turnURL") ?? ""
        turnUser = d.string(forKey: "turnUser") ?? ""
        turnPass = d.string(forKey: "turnPass") ?? ""
        keepAlive = d.object(forKey: "keepAlive") as? Bool ?? true
        if let data = d.data(forKey: "friends"), let f = try? JSONDecoder().decode([Friend].self, from: data) { friends = f }
        if let data = d.data(forKey: "lastRead"), let l = try? JSONDecoder().decode([String: Double].self, from: data) { lastRead = l }
        loadMessages()

        mqtt.onState = { [weak self] b, up in Task { @MainActor in self?.brokerState(b, up) } }
        mqtt.onConnected = { [weak self] b in Task { @MainActor in self?.mqttConnected(b) } }
        mqtt.onMessage = { [weak self] topic, data, b in Task { @MainActor in self?.mqttMessage(topic, data, b) } }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        if keepAlive { KeepAlive.shared.set(true) }
    }

    // MARK: الحساب

    func register(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard Fmt.validUsername(n) else { return false }
        username = n
        start()
        return true
    }

    // MARK: الاتصال بالسيرفر العام

    private func inbox(_ u: String) -> String { "shilla/\(Secrets.ns)/u/\(u)" }
    private var presencePrefix: String { "shilla/\(Secrets.ns)/p/" }
    private func presence(_ u: String) -> String { presencePrefix + u }

    func start() {
        guard isSetup else { return }
        mqtt.connect(clientId: "shilla-\(Secrets.ns.prefix(6))-\(username)-\(deviceId)",
                     willTopic: presence(username),
                     willPayload: Data("0".utf8))
    }

    private var brokersUp = Set<Int>()
    /// حضور كل صديق على كل سيرفر: نعتبره متصل لو ظاهر على أي سيرفر
    private var presenceBy: [String: [Int: Bool]] = [:]
    /// بصمات آخر الرسائل حتى نشيل المكرر (كل رسالة توصل من 3 سيرفرات)
    private var seen = Set<Data>()
    private var seenOrder: [Data] = []

    private func brokerState(_ b: Int, _ up: Bool) {
        if up { brokersUp.insert(b) } else {
            brokersUp.remove(b)
            // حضور هذا السيرفر ما عاد نعرفه، نشيله
            for u in presenceBy.keys { presenceBy[u]?[b] = nil; recomputePresence(u) }
        }
        mqttUp = !brokersUp.isEmpty
    }

    private func mqttConnected(_ b: Int) {
        mqtt.subscribe(inbox(username))
        for f in friends { mqtt.subscribe(presence(f.id)) }
        mqtt.publish(topic: presence(username), payload: Data("1".utf8), retain: true, only: b)
        if brokersUp.count <= 1 { resumeCloudDownloads() }
    }

    private func mqttMessage(_ topic: String, _ data: Data, _ b: Int) {
        if topic.hasPrefix(presencePrefix) {
            let u = String(topic.dropFirst(presencePrefix.count))
            guard u != username else { return }
            presenceBy[u, default: [:]][b] = (data == Data("1".utf8))
            recomputePresence(u)
            return
        }
        guard topic == inbox(username) else { return }
        // نفس الرسالة توصل من أكثر من سيرفر: نعالجها مرة وحدة
        let fp = Data(SHA256.hash(data: data))
        guard !seen.contains(fp) else { return }
        seen.insert(fp)
        seenOrder.append(fp)
        if seenOrder.count > 2000 { seen.remove(seenOrder.removeFirst()) }
        guard let d = Crypt.open(data),
              let from = (d["from"] as? String)?.lowercased(), from != username,
              let t = d["t"] as? String else { return }
        handleInbox(t, from, d)
    }

    private func sendTo(_ peer: String, _ dict: [String: Any]) {
        var d = dict
        d["from"] = username
        d["sent"] = Date().timeIntervalSince1970
        guard let sealed = Crypt.seal(d) else { return }
        // إشارات الاتصال ما تنخزن: لو وصلت متأخرة تخرّب اتصال جديد
        let signal = ["offer", "answer", "ice", "want"].contains(dict["t"] as? String ?? "")
        mqtt.publish(topic: inbox(peer), payload: sealed, queue: !signal)
    }

    private func recomputePresence(_ u: String) {
        let on = presenceBy[u]?.values.contains(true) ?? false
        if online[u] != on { presenceChanged(u, on: on) }
    }

    private func presenceChanged(_ u: String, on: Bool) {
        online[u] = on
        if on {
            ensureLink(u)
            autoResume(u)
        } else {
            links[u]?.close()
            links[u] = nil
            linkStates[u] = nil
        }
    }

    private func handleInbox(_ t: String, _ from: String, _ d: [String: Any]) {
        // الإشارات المخزنة عند السيرفر من زمان (وقت كنا أوفلاين) نتجاهلها
        if ["offer", "answer", "ice", "want"].contains(t),
           let sent = (d["sent"] as? NSNumber)?.doubleValue,
           Date().timeIntervalSince1970 - sent > 600 { return }
        switch t {
        case "chat":
            guard let id = d["id"] as? String, let text = d["text"] as? String else { return }
            addFriendIfNeeded(from)
            let m = ChatMessage(id: id, peer: from, ts: (d["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970,
                                text: text, batch: nil, outgoing: false, localRel: nil, status: nil, delivered: nil)
            sendTo(from, ["t": "ack", "id": id])
            if appendMessage(m) {
                if activeChat == from { markRead(from) }
                notify(from, text)
            }
        case "ack":
            if let id = d["id"] as? String, let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].delivered = true
                scheduleSave()
            }
        case "offer":
            guard let sdp = d["sdp"] as? String else { return }
            let lid = d["lid"] as? String ?? ""
            let ln = (d["ln"] as? NSNumber)?.intValue ?? 0
            let lts = (d["lts"] as? NSNumber)?.doubleValue ?? 0
            addFriendIfNeeded(from)
            if let l = links[from], l.lid == lid, !l.initiator {
                // حارة إضافية لنفس الاتصال
                l.handleOffer(lane: ln, sdp)
                return
            }
            // عرض من اتصال قديم (توصل الرسائل بترتيب مختلف من السيرفرات): نتجاهله
            if retiredLids.contains(lid) { return }
            if let cur = linkTs[from], lts > 0, lts < cur { return }
            // لو الاثنين عرضوا بنفس الوقت: اللي اسمه أكبر هو اللي يكمل
            if let l = links[from], l.initiator, !l.hasRemote, username > from { return }
            makeLink(from, initiator: false, lid: lid)
            if lts > 0 { linkTs[from] = lts }
            links[from]?.handleOffer(lane: ln, sdp)
            // نطبق أي مرشحات وصلت قبل العرض
            if let early = earlyIce.removeValue(forKey: lid) {
                for (eln, ed) in early { links[from]?.handleIce(lane: eln, ed) }
            }
        case "answer":
            // نتجاهل أي رد من اتصال قديم
            guard let sdp = d["sdp"] as? String, let l = links[from], l.lid == (d["lid"] as? String ?? "") else { return }
            l.handleAnswer(lane: (d["ln"] as? NSNumber)?.intValue ?? 0, sdp)
        case "ice":
            let lid = d["lid"] as? String ?? ""
            let ln = (d["ln"] as? NSNumber)?.intValue ?? 0
            if let l = links[from], l.lid == lid {
                l.handleIce(lane: ln, d)
            } else if !retiredLids.contains(lid), !lid.isEmpty {
                // وصل قبل العرض: نخزنه شوي
                if earlyIce.count > 8 { earlyIce.removeAll() }
                earlyIce[lid, default: []].append((ln, SendableMeta(d).value))
            }
        case "cloud":
            guard let bid = d["bid"] as? String, let mk = d["mk"] as? String,
                  let name = d["bname"] as? String else { return }
            guard !messages.contains(where: { $0.id == bid }) else { return }
            addFriendIfNeeded(from)
            let b = BatchInfo(bid: bid, name: name, size: (d["bsize"] as? NSNumber)?.int64Value ?? 0,
                              count: (d["bcount"] as? NSNumber)?.intValue ?? 1,
                              isFolder: (d["folder"] as? NSNumber)?.boolValue ?? false,
                              kind: d["kind"] as? String ?? "file")
            appendMessage(ChatMessage(id: bid, peer: from, ts: Date().timeIntervalSince1970, text: nil,
                                      batch: b, outgoing: false, localRel: nil, status: "active", delivered: nil))
            savePending(bid, from: from, mk: mk)
            progress[bid] = TransferState()
            refreshActivity()
            Task { await cloudReceive(bid: bid, from: from, mk: mk) }
        case "cancel":
            guard let bid = d["bid"] as? String, let m = messages.first(where: { $0.id == bid }), m.peer == from else { return }
            cancelled.insert(bid)
            sendTasks[bid]?.cancel()
            if progress[bid].map({ !$0.finished }) ?? (m.status == "active") {
                finish(bid, ok: false, note: "ألغاه @\(from)", quiet: true)
                markCancelled(bid)
            }
        case "want":
            addFriendIfNeeded(from)
            // لو عندنا اتصال شغال أو قاعد يتجهز من أقل من 10 ثواني، ما نهدمه
            if let l = links[from], l.initiator,
               l.isConnected || (l.state == "connecting" && Date().timeIntervalSince(l.created) < 10) { return }
            makeLink(from, initiator: true)
        default: break
        }
    }

    // MARK: الأصدقاء

    @discardableResult
    func addFriend(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ ").union(.whitespaces))
        guard Fmt.validUsername(n), n != username else { return false }
        addFriendIfNeeded(n)
        return true
    }

    private func addFriendIfNeeded(_ u: String) {
        guard !friends.contains(where: { $0.id == u }) else { return }
        friends.append(Friend(id: u, addedAt: Date().timeIntervalSince1970))
        saveFriends()
        mqtt.subscribe(presence(u))
    }

    func removeFriend(_ u: String) {
        friends.removeAll { $0.id == u }
        links[u]?.close(); links[u] = nil
        saveFriends()
    }

    private func saveFriends() {
        if let d = try? JSONEncoder().encode(friends) { UserDefaults.standard.set(d, forKey: "friends") }
    }

    // MARK: الاتصال المباشر

    private func ensureLink(_ u: String) {
        guard friends.contains(where: { $0.id == u }) else { return }
        if let l = links[u], l.state != "failed", l.state != "closed" { return }
        if username > u { makeLink(u, initiator: true) }
        // غير كذا ننتظر هو يبدأ (يوصله حضورنا المحفوظ)
    }

    private func makeLink(_ u: String, initiator: Bool, lid: String = UUID().uuidString) {
        if let old = links[u] {
            retiredLids.insert(old.lid)
            if retiredLids.count > 200 { retiredLids.removeAll() }
            old.close()
        }
        if initiator { linkTs[u] = nil }
        let link = PeerLink(
            peerId: u,
            initiator: initiator,
            lid: lid,
            sendSignal: { [weak self] d in
                Task { @MainActor in self?.sendTo(u, d) }
            },
            makeIncoming: { [weak self] tid in
                IncomingFile(tid: tid, from: u, ev: Self.events(self))
            })
        link.onState = { [weak self] st in
            Task { @MainActor in self?.linkState(u, link, st) }
        }
        link.onLanes = { [weak self] n in
            Task { @MainActor in
                guard let self, self.links[u] === link else { return }
                self.lanes[u] = n
            }
        }
        lanes[u] = 0
        links[u] = link
        linkStates[u] = "connecting"
        if initiator { link.makeOffer() }
    }

    private func linkState(_ u: String, _ link: PeerLink, _ st: String) {
        guard links[u] === link else { return }
        linkStates[u] = st
        if st == "failed" {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.links[u] === link, self.linkStates[u] == "failed", self.online[u] == true {
                    self.requestConnection(u)
                }
            }
        }
    }

    /// يطلب اتصال مباشر مع صديق (إما نبدأ إحنا أو نطلب منه)
    func requestConnection(_ u: String) {
        if username > u { makeLink(u, initiator: true) } else { sendTo(u, ["t": "want"]) }
    }

    func isDirect(_ u: String) -> Bool { linkStates[u] == "connected" }

    // MARK: الدردشة

    func chat(_ peer: String) -> [ChatMessage] {
        messages.filter { $0.peer == peer }
    }

    func last(_ peer: String) -> ChatMessage? {
        messages.last { $0.peer == peer }
    }

    func unread(_ peer: String) -> Int {
        let lr = lastRead[peer] ?? 0
        return messages.filter { $0.peer == peer && !$0.outgoing && $0.ts > lr }.count
    }

    var totalUnread: Int { friends.reduce(0) { $0 + unread($1.id) } }

    var fileMessages: [ChatMessage] {
        messages.filter { $0.batch != nil }.sorted { $0.ts > $1.ts }
    }

    func markRead(_ peer: String) {
        guard !locked else { return }
        lastRead[peer] = Date().timeIntervalSince1970 + 1
        if let d = try? JSONEncoder().encode(lastRead) { UserDefaults.standard.set(d, forKey: "lastRead") }
    }

    func sendText(_ t: String, to peer: String) {
        let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let m = ChatMessage(id: UUID().uuidString, peer: peer, ts: Date().timeIntervalSince1970,
                            text: text, batch: nil, outgoing: true, localRel: nil, status: nil, delivered: false)
        appendMessage(m)
        sendTo(peer, ["t": "chat", "id": m.id, "text": text, "ts": m.ts])
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @discardableResult
    private func appendMessage(_ m: ChatMessage) -> Bool {
        if messages.contains(where: { $0.id == m.id }) { return false }
        messages.append(m)
        scheduleSave()
        return true
    }

    // MARK: حفظ وتحميل

    private func loadMessages() {
        guard let data = try? Data(contentsOf: Paths.messagesFile),
              var list = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        for i in list.indices where list[i].status == "active" { list[i].status = "failed" }
        messages = list
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if let d = try? JSONEncoder().encode(self.messages) {
                try? d.write(to: Paths.messagesFile, options: .atomic)
            }
        }
    }

    // MARK: التقدّم

    private func setBytes(_ bid: String, _ bytes: Int64, force: Bool = false) {
        let now = Date()
        if !force, let lp = lastPublish[bid], now.timeIntervalSince(lp) < 0.25 { return }
        lastPublish[bid] = now
        var st = progress[bid] ?? TransferState()
        if let ls = lastSample[bid] {
            let dt = now.timeIntervalSince(ls.0)
            if dt >= 0.8 {
                let inst = max(0, Double(bytes - ls.1) / dt)
                st.speed = st.speed == 0 ? inst : (st.speed * 0.5 + inst * 0.5)
                lastSample[bid] = (now, bytes)
            }
        } else {
            lastSample[bid] = (now, bytes)
        }
        if st.started == nil && bytes > 0 { st.started = now; st.startBytes = st.bytes }
        st.bytes = bytes
        progress[bid] = st
    }

    private func finish(_ bid: String, ok: Bool, note: String = "", quiet: Bool = false) {
        var st = progress[bid] ?? TransferState()
        if ok, let t0 = st.started {
            let dt = Date().timeIntervalSince(t0)
            let moved = (messages.first { $0.id == bid }?.batch?.size ?? st.bytes) - st.startBytes
            if dt > 1, moved > 0 { st.avg = Double(moved) / dt }
        }
        if !quiet && UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        }
        st.finished = ok
        st.failed = !ok
        st.speed = 0
        st.note = note
        if ok, let m = messages.first(where: { $0.id == bid }), let b = m.batch { st.bytes = b.size }
        progress[bid] = st
        if let i = messages.firstIndex(where: { $0.id == bid }) {
            messages[i].status = ok ? "done" : "failed"
        }
        scheduleSave()
        refreshActivity()
    }

    private func refreshActivity() {
        let active = progress.values.contains { !$0.finished && !$0.failed }
        UIApplication.shared.isIdleTimerDisabled = active
    }

    // MARK: الاستقبال

    private nonisolated static func events(_ s: AppState?) -> RecvEvents {
        RecvEvents(
            onStart: { meta, from in Task { @MainActor in s?.recvStart(meta, from) } },
            onProgress: { meta, from, b in Task { @MainActor in s?.recvProgress(meta, b) } },
            onFinish: { meta, from, top in Task { @MainActor in s?.recvFinish(meta, from, top) } },
            onFail: { meta, from in Task { @MainActor in s?.recvFail(meta) } })
    }

    private func recvStart(_ meta: FileMeta, _ from: String) {
        if let i = messages.firstIndex(where: { $0.id == meta.bid }) {
            // استكمال بعد انقطاع أو إعادة إرسال: نرجّع الحالة لـ «جاري»
            if progress[meta.bid]?.failed == true || messages[i].status == "failed" || messages[i].status == "cancelled" {
                cancelled.remove(meta.bid)
                var st = progress[meta.bid] ?? TransferState()
                st.failed = false
                st.note = ""
                progress[meta.bid] = st
                messages[i].status = "active"
                refreshActivity()
            }
            return
        }
        let b = BatchInfo(bid: meta.bid, name: meta.bname, size: meta.bsize, count: meta.bcount,
                          isFolder: meta.isFolder, kind: meta.kind)
        appendMessage(ChatMessage(id: meta.bid, peer: from, ts: Date().timeIntervalSince1970, text: nil,
                                  batch: b, outgoing: false, localRel: nil, status: "active", delivered: nil))
        addFriendIfNeeded(from)
        progress[meta.bid] = TransferState()
        recvBase[meta.bid] = 0
        recvCount[meta.bid] = 0
        refreshActivity()
    }

    private func recvProgress(_ meta: FileMeta, _ bytes: Int64) {
        guard progress[meta.bid]?.failed != true, progress[meta.bid]?.finished != true else { return }
        recvLive[meta.bid, default: [:]][meta.rel] = bytes
        let live = recvLive[meta.bid]?.values.reduce(0, +) ?? 0
        setBytes(meta.bid, (recvBase[meta.bid] ?? 0) + live)
    }

    private func recvFinish(_ meta: FileMeta, _ from: String, _ top: String) {
        guard !cancelled.contains(meta.bid) else { return }
        recvLive[meta.bid]?[meta.rel] = nil
        // ملف وصل من قبل (إعادة إرسال للمجلد كامل): ما نعدّه مرة ثانية
        guard recvDone[meta.bid, default: []].insert(meta.rel).inserted else { return }
        recvBase[meta.bid, default: 0] += meta.size
        recvCount[meta.bid, default: 0] += 1
        let count = recvCount[meta.bid] ?? 0
        if let i = messages.firstIndex(where: { $0.id == meta.bid }) {
            messages[i].localRel = top
        }
        var st = progress[meta.bid] ?? TransferState()
        st.files = count
        progress[meta.bid] = st
        let live = recvLive[meta.bid]?.values.reduce(0, +) ?? 0
        setBytes(meta.bid, (recvBase[meta.bid] ?? 0) + live, force: true)
        if count >= meta.bcount {
            recvLive[meta.bid] = nil
            finish(meta.bid, ok: true)
            if activeChat == from { markRead(from) }
            notify(from, "وصلك: \(meta.bname)")
        }
    }

    private func recvFail(_ meta: FileMeta) {
        guard progress[meta.bid]?.finished != true, !cancelled.contains(meta.bid) else { return }
        finish(meta.bid, ok: false, note: "انقطع النقل. بيكمل تلقائياً لما يرجع الاتصال.")
    }

    // MARK: الإرسال

    func startSend(urls: [URL], to peer: String) {
        guard !urls.isEmpty else { return }
        Task { await runSend(urls, peer) }
    }

    private var lastRequest: [String: Date] = [:]
    private var retiredLids = Set<String>()
    private var linkTs: [String: Double] = [:]
    private var earlyIce: [String: [(Int, [String: Any])]] = [:]
    /// الملفات اللي وصلت كاملة في كل دفعة (حتى ما ننحسب مرتين عند إعادة الإرسال)
    private var recvDone: [String: Set<String>] = [:]
    private var sendTasks: [String: Task<Void, Never>] = [:]
    private var cancelled = Set<String>()

    private func waitConnected(_ peer: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !Task.isCancelled {
            if links[peer]?.isConnected == true { return true }
            // نطلب اتصال جديد فقط لو ما فيه اتصال شغال أو قيد التجهيز،
            // ومو أكثر من مرة كل 8 ثواني (حتى ما نقطع اتصال قاعد يتجهز)
            let l = links[peer]
            let stuck = l.map { $0.state == "connecting" && Date().timeIntervalSince($0.created) > 25 } ?? false
            let dead = l == nil || l?.state == "failed" || l?.state == "closed" || stuck
            let recent = lastRequest[peer].map { Date().timeIntervalSince($0) < 8 } ?? false
            if dead && !recent && online[peer] == true {
                lastRequest[peer] = Date()
                requestConnection(peer)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return links[peer]?.isConnected == true
    }

    /// ننتظر لين الصديق يدخل (بدون حد). الملف يظهر في الشات بحالة انتظار.
    private func waitOnline(_ peer: String, _ bid: String) async {
        guard online[peer] != true else { return }
        var st = progress[bid] ?? TransferState()
        st.note = "بانتظار دخول @\(peer)… خلّ التطبيق مفتوح"
        progress[bid] = st
        while online[peer] != true && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        st = progress[bid] ?? TransferState()
        st.note = ""
        progress[bid] = st
    }

    private func runSend(_ urls: [URL], _ peer: String) async {
        if online[peer] != true && links[peer]?.isConnected != true {
            showToast("@\(peer) مو متصل. الملف بيوصله أول ما يدخل التطبيق")
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let listing = Self.listFiles(url)
            if listing.files.isEmpty { showToast("ما لقيت ملفات داخل: \(url.lastPathComponent)"); continue }

            let bid = UUID().uuidString
            var sentRel: String? = nil
            let docPath = Paths.documents.standardizedFileURL.path + "/"
            if url.standardizedFileURL.path.hasPrefix(docPath) {
                sentRel = String(url.standardizedFileURL.path.dropFirst(docPath.count))
            } else if let bm = try? url.bookmarkData() {
                UserDefaults.standard.set(bm, forKey: "bm_" + bid)
            }
            let total = listing.files.reduce(Int64(0)) { $0 + $1.size }
            let kind = listing.isFolder ? "folder" : Fmt.kind(of: url.lastPathComponent)
            let batch = BatchInfo(bid: bid, name: url.lastPathComponent, size: total,
                                  count: listing.files.count, isFolder: listing.isFolder, kind: kind)
            appendMessage(ChatMessage(id: bid, peer: peer, ts: Date().timeIntervalSince1970, text: nil,
                                      batch: batch, outgoing: true, localRel: sentRel, status: "active", delivered: nil))
            progress[bid] = TransferState()
            refreshActivity()

            let t = Task { await self.transferBatch(listing: listing, bid: bid, batch: batch, peer: peer) }
            sendTasks[bid] = t
            await t.value
            sendTasks[bid] = nil
            let tmp = FileManager.default.temporaryDirectory.path
            if url.path.hasPrefix(tmp) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// ينقل دفعة وحدة (ملف أو مجلد). تنلغي بـ cancel على مهمتها.
    private func transferBatch(listing: (isFolder: Bool, files: [FileItem]), bid: String, batch: BatchInfo, peer: String) async {
        if online[peer] != true, links[peer]?.isConnected != true, Relay.configured {
            await cloudSend(listing: listing, bid: bid, batch: batch, peer: peer)
            return
        }

        // الملفات الكبيرة وحدة وحدة (تاخذ الخط كامل)، والصغيرة عدة ملفات بنفس الوقت
        // حتى ما يضيع الوقت بانتظار الردود بين ملف وملف.
        let tr = BatchTracker()
        var failedAll = false
        let maxParallel = 4
        let bigFile: Int64 = 64 * 1024 * 1024

        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            var running = 0
            func launch() {
                while next < listing.files.count && running < maxParallel && !failedAll {
                    let idx = next
                    let f = listing.files[idx]
                    // ملف كبير ما يشتغل مع غيره
                    if f.size >= bigFile && running > 0 { break }
                    next += 1
                    running += 1
                    let meta: [String: Any] = [
                        "bid": bid, "bname": batch.name, "bsize": batch.size, "bcount": batch.count,
                        "folder": batch.isFolder, "kind": batch.kind, "rel": f.rel, "size": f.size,
                    ]
                    let sendable = SendableMeta(meta)
                    group.addTask { @MainActor in
                        let ok = await self.sendOne(f, meta: sendable.value, peer: peer, bid: bid) { cur in
                            tr.live[idx] = cur
                            self.setBytes(bid, tr.total)
                        }
                        return (idx, ok)
                    }
                    if f.size >= bigFile { break }
                }
            }
            launch()
            while let r = await group.next() {
                let (idx, ok) = r
                running -= 1
                tr.live[idx] = nil
                if ok {
                    tr.base += listing.files[idx].size
                    tr.done += 1
                    var st = progress[bid] ?? TransferState()
                    st.files = tr.done
                    st.note = ""
                    progress[bid] = st
                    setBytes(bid, tr.total, force: true)
                } else {
                    failedAll = true
                }
                launch()
            }
        }

        // لو انلغى ما نكتب فوق حالة «أُلغي»
        if Task.isCancelled || cancelled.contains(bid) { return }
        if failedAll {
            finish(bid, ok: false, note: "ما اكتمل الإرسال. أعد الإرسال وبيكمل من نفس المكان.")
        } else {
            finish(bid, ok: true)
        }
    }

    /// إعادة إرسال دفعة فشلت: نفس الرسالة، والمستقبِل يكمل من حيث وقف.
    func retrySend(_ m: ChatMessage, silent: Bool = false) {
        guard m.outgoing, let b = m.batch, sendTasks[m.id] == nil else { return }
        guard let url = fileURL(for: m) else {
            if !silent { showToast("ما لقيت الملف الأصلي، أرسله من جديد") }
            return
        }
        cancelled.remove(m.id)
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].status = "active" }
        progress[m.id] = TransferState()
        lastSample[m.id] = nil
        refreshActivity()
        let peer = m.peer
        let bid = m.id
        // المهمة تتسجل فوراً حتى أي إلغاء يوصل الحين يوقفها
        sendTasks[bid] = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let listing = Self.listFiles(url)
            if listing.files.isEmpty {
                self.finish(bid, ok: false, note: "الملف الأصلي انحذف")
            } else if !Task.isCancelled {
                await self.transferBatch(listing: listing, bid: bid, batch: b, peer: peer)
            }
            self.sendTasks[bid] = nil
        }
    }

    /// إلغاء نقل (إرسال أو استقبال). نبلّغ الطرف الثاني بعد.
    func cancelTransfer(_ bid: String) {
        guard let m = messages.first(where: { $0.id == bid }) else { return }
        cancelled.insert(bid)
        sendTasks[bid]?.cancel()
        sendTo(m.peer, ["t": "cancel", "bid": bid])
        finish(bid, ok: false, note: "أُلغي النقل", quiet: true)
        markCancelled(bid)
    }

    private func markCancelled(_ bid: String) {
        if let i = messages.firstIndex(where: { $0.id == bid }) { messages[i].status = "cancelled" }
        scheduleSave()
    }

    /// لما يرجع الصديق متصل: نكمل تلقائياً أي إرسال انقطع (آخر يومين، مو الملغية)
    private func autoResume(_ u: String) {
        let cutoff = Date().timeIntervalSince1970 - 2 * 86400
        let list = messages.filter {
            $0.peer == u && $0.outgoing && $0.batch != nil && $0.status == "failed" && $0.ts > cutoff
                && !cancelled.contains($0.id) && sendTasks[$0.id] == nil
        }
        for m in list { retrySend(m, silent: true) }
    }

    func isSending(_ bid: String) -> Bool { sendTasks[bid] != nil }

    /// حذف رسالة من المحادثة (الملف نفسه يبقى في «الملفات»)
    func deleteMessage(_ id: String) {
        if progress[id].map({ !$0.finished && !$0.failed }) == true { cancelTransfer(id) }
        messages.removeAll { $0.id == id }
        progress[id] = nil
        scheduleSave()
        refreshActivity()
    }

    /// يرسل ملف واحد مع إعادة المحاولة. الاستكمال من نفس المكان يصير تلقائياً عند المستقبِل.
    private func sendOne(_ f: FileItem, meta: [String: Any], peer: String, bid: String,
                         onBytes: @escaping @MainActor (Int64) -> Void) async -> Bool {
        var attempt = 0
        while attempt < 8 {
            if Task.isCancelled || cancelled.contains(bid) { return false }
            await waitOnline(peer, bid)
            if Task.isCancelled { return false }
            attempt += 1
            let connected = await waitConnected(peer, timeout: attempt == 1 ? 20 : 90)
            guard connected, let link = links[peer] else {
                if attempt >= 4 { return false }
                continue
            }
            do {
                try await link.sendFile(meta: meta, url: f.url, size: UInt64(f.size)) { cur in
                    Task { @MainActor in onBytes(cur) }
                }
                return true
            } catch {
                if Task.isCancelled { return false }
                var st = progress[bid] ?? TransferState()
                st.note = "انقطع الاتصال، جاري إعادة المحاولة…"
                progress[bid] = st
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        return false
    }

    private nonisolated static func listFiles(_ url: URL) -> (isFolder: Bool, files: [FileItem]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (false, []) }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let sz = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return (false, [FileItem(url: url, rel: url.lastPathComponent, size: sz)])
        }
        var out: [FileItem] = []
        let root = url.lastPathComponent
        let rootPath = url.standardizedFileURL.path
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v?.isRegularFile == true else { continue }
                let p = u.standardizedFileURL.path
                var sub = p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : u.lastPathComponent
                if sub.hasPrefix("/") { sub.removeFirst() }
                out.append(FileItem(url: u, rel: root + "/" + sub, size: Int64(v?.fileSize ?? 0)))
            }
        }
        out.sort { $0.rel < $1.rel }
        return (true, out)
    }

    // MARK: الوسيط السحابي

    private func cloudSend(listing: (isFolder: Bool, files: [FileItem]), bid: String, batch: BatchInfo, peer: String) async {
        var st = progress[bid] ?? TransferState()
        st.note = "جاري الرفع للخدمة، وصديقك ينزّله لما يدخل"
        progress[bid] = st
        var base: Int64 = 0
        var manifest: [[String: Any]] = []
        do {
            for (i, f) in listing.files.enumerated() {
                let key = "\(bid)/\(i)"
                let b0 = base
                try await Relay.upload(url: f.url, size: f.size, key: key) { cur in
                    Task { @MainActor in self.setBytes(bid, b0 + cur) }
                }
                manifest.append(["rel": f.rel, "size": f.size, "k": key])
                base += f.size
            }
            let md = try JSONSerialization.data(withJSONObject: manifest)
            try await Relay.put(key: "\(bid)/manifest", data: md)
            sendTo(peer, ["t": "cloud", "bid": bid, "mk": "\(bid)/manifest", "bname": batch.name,
                          "bsize": batch.size, "bcount": batch.count, "folder": batch.isFolder, "kind": batch.kind])
            var s2 = progress[bid] ?? TransferState()
            s2.note = ""
            progress[bid] = s2
            setBytes(bid, base, force: true)
            finish(bid, ok: true)
        } catch {
            if Task.isCancelled || cancelled.contains(bid) { return }
            finish(bid, ok: false, note: "فشل الرفع: \(error.localizedDescription). أعد الإرسال.")
        }
    }

    private func savePending(_ bid: String, from: String, mk: String) {
        var p = UserDefaults.standard.dictionary(forKey: "pendingCloud") as? [String: [String]] ?? [:]
        p[bid] = [from, mk]
        UserDefaults.standard.set(p, forKey: "pendingCloud")
    }

    private func clearPending(_ bid: String) {
        var p = UserDefaults.standard.dictionary(forKey: "pendingCloud") as? [String: [String]] ?? [:]
        p[bid] = nil
        UserDefaults.standard.set(p, forKey: "pendingCloud")
    }

    /// لو التطبيق انقفل أثناء تنزيل من الوسيط نكمله.
    func resumeCloudDownloads() {
        let p = UserDefaults.standard.dictionary(forKey: "pendingCloud") as? [String: [String]] ?? [:]
        for (bid, v) in p where v.count == 2 {
            guard progress[bid] == nil, let i = messages.firstIndex(where: { $0.id == bid }) else {
                if messages.first(where: { $0.id == bid }) == nil { clearPending(bid) }
                continue
            }
            messages[i].status = "active"
            progress[bid] = TransferState()
            let from = v[0], mk = v[1]
            Task { await cloudReceive(bid: bid, from: from, mk: mk) }
        }
        refreshActivity()
    }

    private func cloudReceive(bid: String, from: String, mk: String) async {
        let fm = FileManager.default
        var attempt = 0
        while attempt < 8 {
            if cancelled.contains(bid) { clearPending(bid); return }
            attempt += 1
            do {
                let md = try await Relay.getData(key: mk)
                guard let arr = try JSONSerialization.jsonObject(with: md) as? [[String: Any]] else {
                    throw Relay.Fail(msg: "قائمة الملفات تالفة")
                }
                var base: Int64 = 0
                var top = ""
                for f in arr {
                    guard let rel = f["rel"] as? String, let k = f["k"] as? String,
                          let size = (f["size"] as? NSNumber)?.int64Value else { continue }
                    let comps = rel.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
                    guard !comps.isEmpty else { continue }
                    var dest = Paths.received
                    for c in comps { dest.appendPathComponent(c) }
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    var finalURL = dest
                    if fm.fileExists(atPath: dest.path) {
                        let ex = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
                        if ex == size {
                            if top.isEmpty { top = comps[0] }
                            base += size
                            continue
                        }
                        finalURL = Self.uniqueURL(dest)
                    }
                    if cancelled.contains(bid) { clearPending(bid); return }
                    if top.isEmpty { top = comps.count == 1 ? finalURL.lastPathComponent : comps[0] }
                    let part = finalURL.appendingPathExtension("part")
                    let b0 = base
                    try await Relay.download(key: k, to: part, total: size) { cur in
                        Task { @MainActor in self.setBytes(bid, b0 + cur) }
                    }
                    try? fm.removeItem(at: finalURL)
                    try fm.moveItem(at: part, to: finalURL)
                    base += size
                }
                if let i = messages.firstIndex(where: { $0.id == bid }) { messages[i].localRel = "Received/" + top }
                var st = progress[bid] ?? TransferState()
                st.note = ""
                progress[bid] = st
                setBytes(bid, base, force: true)
                finish(bid, ok: true)
                clearPending(bid)
                if activeChat == from { markRead(from) }
                notify(from, "وصلك: " + (messages.first { $0.id == bid }?.batch?.name ?? "ملف"))
                for f in arr { if let k = f["k"] as? String { await Relay.delete(key: k) } }
                await Relay.delete(key: mk)
                return
            } catch {
                var st = progress[bid] ?? TransferState()
                st.note = "انقطع التحميل، جاري إعادة المحاولة…"
                progress[bid] = st
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 4_000_000_000)
            }
        }
        finish(bid, ok: false, note: "ما قدرت أنزّله. افتح التطبيق مرة ثانية وبيكمل.")
    }

    private nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }

    // MARK: أدوات

    func fileURL(for m: ChatMessage) -> URL? {
        guard let rel = m.localRel else {
            if m.outgoing, let bm = UserDefaults.standard.data(forKey: "bm_" + m.id) {
                var stale = false
                if let u = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) {
                    _ = u.startAccessingSecurityScopedResource()
                    return FileManager.default.fileExists(atPath: u.path) ? u : nil
                }
            }
            return nil
        }
        let u = Paths.documents.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func saveToPhotos(_ url: URL, video: Bool) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in self.showToast("ما عندي صلاحية الصور") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: url, options: nil)
            }) { ok, _ in
                Task { @MainActor in self.showToast(ok ? "انحفظ في الصور" : "ما قدرت أحفظه") }
            }
        }
    }

    func openInFiles(_ url: URL) {
        let s = "shareddocuments://" + url.path
        if let u = URL(string: s) { UIApplication.shared.open(u) }
    }

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.toast == s { self.toast = nil }
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard UIApplication.shared.applicationState != .active || locked else { return }
        // تنبيه متخفي بشكل لعبة (ما يبين اسم المرسل ولا المحتوى)
        let c = UNMutableNotificationContent()
        c.title = "Jelly Jum"
        c.body = "🎁 مكافأة جديدة بانتظارك!"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
