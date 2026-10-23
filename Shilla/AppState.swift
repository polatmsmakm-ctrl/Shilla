import SwiftUI
import UserNotifications
import Photos
import WebRTC

struct FileItem {
    let url: URL
    let rel: String
    let size: Int64
}

@MainActor
final class AppState: ObservableObject {
    // الهوية والإعدادات
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: "username") } }
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
    @Published var lastRead: [String: Double] = [:]
    @Published var mqttUp = false
    @Published var toast: String?
    var activeChat: String?

    private let mqtt = MQTTClient()
    private var links: [String: PeerLink] = [:]
    private var saveTask: Task<Void, Never>?
    private let deviceId: String

    private var lastSample: [String: (Date, Int64)] = [:]
    private var lastPublish: [String: Date] = [:]
    private var recvBase: [String: Int64] = [:]
    private var recvCount: [String: Int] = [:]

    var isSetup: Bool { !username.isEmpty }

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "did") { deviceId = id } else {
            deviceId = String(UUID().uuidString.prefix(8)).lowercased()
            d.set(deviceId, forKey: "did")
        }
        username = d.string(forKey: "username") ?? ""
        turnURL = d.string(forKey: "turnURL") ?? ""
        turnUser = d.string(forKey: "turnUser") ?? ""
        turnPass = d.string(forKey: "turnPass") ?? ""
        keepAlive = d.object(forKey: "keepAlive") as? Bool ?? true
        if let data = d.data(forKey: "friends"), let f = try? JSONDecoder().decode([Friend].self, from: data) { friends = f }
        if let data = d.data(forKey: "lastRead"), let l = try? JSONDecoder().decode([String: Double].self, from: data) { lastRead = l }
        loadMessages()

        mqtt.onState = { [weak self] up in Task { @MainActor in self?.mqttUp = up } }
        mqtt.onConnected = { [weak self] in Task { @MainActor in self?.mqttConnected() } }
        mqtt.onMessage = { [weak self] topic, data in Task { @MainActor in self?.mqttMessage(topic, data) } }
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

    private func mqttConnected() {
        mqtt.subscribe(inbox(username))
        for f in friends { mqtt.subscribe(presence(f.id)) }
        mqtt.publish(topic: presence(username), payload: Data("1".utf8), retain: true)
    }

    private func mqttMessage(_ topic: String, _ data: Data) {
        if topic.hasPrefix(presencePrefix) {
            let u = String(topic.dropFirst(presencePrefix.count))
            guard u != username else { return }
            presenceChanged(u, on: data == Data("1".utf8))
            return
        }
        guard topic == inbox(username), let d = Crypt.open(data),
              let from = (d["from"] as? String)?.lowercased(), from != username,
              let t = d["t"] as? String else { return }
        handleInbox(t, from, d)
    }

    private func sendTo(_ peer: String, _ dict: [String: Any]) {
        var d = dict
        d["from"] = username
        guard let sealed = Crypt.seal(d) else { return }
        mqtt.publish(topic: inbox(peer), payload: sealed)
    }

    private func presenceChanged(_ u: String, on: Bool) {
        online[u] = on
        if on {
            ensureLink(u)
        } else {
            links[u]?.close()
            links[u] = nil
            linkStates[u] = nil
        }
    }

    private func handleInbox(_ t: String, _ from: String, _ d: [String: Any]) {
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
            addFriendIfNeeded(from)
            // لو الاثنين عرضوا بنفس الوقت: اللي اسمه أكبر هو اللي يكمل
            if let l = links[from], l.initiator, !l.hasRemote, username > from { return }
            makeLink(from, initiator: false)
            links[from]?.handleOffer(sdp)
        case "answer":
            if let sdp = d["sdp"] as? String { links[from]?.handleAnswer(sdp) }
        case "ice":
            links[from]?.handleIce(d)
        case "want":
            addFriendIfNeeded(from)
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

    private func makeLink(_ u: String, initiator: Bool) {
        links[u]?.close()
        let link = PeerLink(
            peerId: u,
            initiator: initiator,
            sendSignal: { [weak self] d in
                Task { @MainActor in self?.sendTo(u, d) }
            },
            makeIncoming: { [weak self] tid in
                IncomingFile(tid: tid, from: u, ev: Self.events(self))
            })
        link.onState = { [weak self] st in
            Task { @MainActor in self?.linkState(u, link, st) }
        }
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
        st.bytes = bytes
        progress[bid] = st
    }

    private func finish(_ bid: String, ok: Bool, note: String = "") {
        var st = progress[bid] ?? TransferState()
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
        guard !messages.contains(where: { $0.id == meta.bid }) else { return }
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
        guard progress[meta.bid]?.failed != true else { return }
        setBytes(meta.bid, (recvBase[meta.bid] ?? 0) + bytes)
    }

    private func recvFinish(_ meta: FileMeta, _ from: String, _ top: String) {
        recvBase[meta.bid, default: 0] += meta.size
        recvCount[meta.bid, default: 0] += 1
        let count = recvCount[meta.bid] ?? 0
        if let i = messages.firstIndex(where: { $0.id == meta.bid }) {
            messages[i].localRel = top
        }
        var st = progress[meta.bid] ?? TransferState()
        st.files = count
        progress[meta.bid] = st
        setBytes(meta.bid, recvBase[meta.bid] ?? 0, force: true)
        if count >= meta.bcount {
            finish(meta.bid, ok: true)
            if activeChat == from { markRead(from) }
            notify(from, "وصلك: \(meta.bname)")
        }
    }

    private func recvFail(_ meta: FileMeta) {
        guard progress[meta.bid]?.finished != true else { return }
        finish(meta.bid, ok: false, note: "انقطع النقل. بيكمل تلقائياً لما يرجع الاتصال.")
    }

    // MARK: الإرسال

    func startSend(urls: [URL], to peer: String) {
        guard !urls.isEmpty else { return }
        Task { await runSend(urls, peer) }
    }

    private func waitConnected(_ peer: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var asked = false
        while Date() < deadline {
            if links[peer]?.isConnected == true { return true }
            if !asked || (links[peer] == nil && online[peer] == true) {
                asked = true
                requestConnection(peer)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return links[peer]?.isConnected == true
    }

    private func runSend(_ urls: [URL], _ peer: String) async {
        if online[peer] != true && links[peer]?.isConnected != true {
            showToast("\(peer) مو متصل الحين")
            return
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

            var base: Int64 = 0
            var doneFiles = 0
            var failedAll = false

            fileLoop: for f in listing.files {
                let b0 = base
                let meta: [String: Any] = [
                    "bid": bid, "bname": batch.name, "bsize": total, "bcount": batch.count,
                    "folder": batch.isFolder, "kind": kind, "rel": f.rel, "size": f.size,
                ]
                var ok = false
                var attempt = 0
                while attempt < 6 && !ok {
                    attempt += 1
                    let connected = await waitConnected(peer, timeout: attempt == 1 ? 20 : 120)
                    guard connected, let link = links[peer] else {
                        if attempt >= 3 { break }
                        continue
                    }
                    do {
                        try await link.sendFile(meta: meta, url: f.url, size: UInt64(f.size)) { cur in
                            Task { @MainActor in self.setBytes(bid, b0 + cur) }
                        }
                        ok = true
                    } catch {
                        var st = progress[bid] ?? TransferState()
                        st.note = "انقطع الاتصال، جاري إعادة المحاولة…"
                        progress[bid] = st
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                }
                if !ok { failedAll = true; break fileLoop }
                base += f.size
                doneFiles += 1
                var st = progress[bid] ?? TransferState()
                st.files = doneFiles
                st.note = ""
                progress[bid] = st
                setBytes(bid, base, force: true)
            }

            if failedAll {
                finish(bid, ok: false, note: "ما اكتمل الإرسال. أعد الإرسال وبيكمل من نفس المكان.")
            } else {
                finish(bid, ok: true)
            }
            let tmp = FileManager.default.temporaryDirectory.path
            if url.path.hasPrefix(tmp) { try? FileManager.default.removeItem(at: url) }
        }
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
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
