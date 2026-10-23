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
    // الإعدادات
    @Published var myName: String { didSet { UserDefaults.standard.set(myName, forKey: "name") } }
    @Published var room: String { didSet { UserDefaults.standard.set(room, forKey: "room") } }
    @Published var server: String { didSet { UserDefaults.standard.set(server, forKey: "server") } }
    @Published var turnURL: String { didSet { UserDefaults.standard.set(turnURL, forKey: "turnURL") } }
    @Published var turnUser: String { didSet { UserDefaults.standard.set(turnUser, forKey: "turnUser") } }
    @Published var turnPass: String { didSet { UserDefaults.standard.set(turnPass, forKey: "turnPass") } }
    @Published var keepAlive: Bool {
        didSet { UserDefaults.standard.set(keepAlive, forKey: "keepAlive"); KeepAlive.shared.set(keepAlive) }
    }

    // الحالة
    @Published var messages: [ChatMessage] = []
    @Published var progress: [String: TransferState] = [:]
    @Published var peers: [String: PeerInfo] = [:]
    @Published var serverUp = false
    @Published var toast: String?

    let myId: String
    private let sig = Signaling()
    private var links: [String: PeerLink] = [:]
    private var saveTask: Task<Void, Never>?

    private var sendTargets: [String: Int] = [:]
    private var peerBytes: [String: [String: Int64]] = [:]
    private var recvBase: [String: Int64] = [:]
    private var recvCount: [String: Int] = [:]
    private var lastSample: [String: (Date, Int64)] = [:]
    private var lastPublish: [String: Date] = [:]

    @Published var setupDone: Bool { didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") } }

    var isConfigured: Bool { setupDone && !myName.isEmpty && !room.isEmpty && !server.isEmpty }

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "pid") { myId = id } else {
            myId = UUID().uuidString
            d.set(myId, forKey: "pid")
        }
        myName = d.string(forKey: "name") ?? ""
        room = d.string(forKey: "room") ?? ""
        server = d.string(forKey: "server") ?? ""
        turnURL = d.string(forKey: "turnURL") ?? ""
        turnUser = d.string(forKey: "turnUser") ?? ""
        turnPass = d.string(forKey: "turnPass") ?? ""
        keepAlive = d.object(forKey: "keepAlive") as? Bool ?? true
        setupDone = d.bool(forKey: "setupDone")
        loadMessages()

        sig.onStatus = { [weak self] up in Task { @MainActor in self?.serverUp = up } }
        sig.onMessage = { [weak self] m in Task { @MainActor in self?.handle(m) } }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        if keepAlive { KeepAlive.shared.set(true) }
    }

    // MARK: الاتصال

    func start() {
        guard isConfigured else { return }
        if serverUp { return }
        sig.connect(server: server, room: room, id: myId, name: myName)
    }

    func reconnect() {
        setupDone = true
        for l in links.values { l.close() }
        links = [:]
        peers = [:]
        serverUp = false
        guard isConfigured else { return }
        sig.connect(server: server, room: room, id: myId, name: myName)
    }

    private func handle(_ m: [String: Any]) {
        guard let type = m["type"] as? String else { return }
        switch type {
        case "peers":
            for p in (m["peers"] as? [[String: Any]] ?? []) {
                guard let id = p["id"] as? String, id != myId else { continue }
                let name = p["name"] as? String ?? "صديق"
                if let l = links[id], l.isConnected { peers[id]?.name = name; continue }
                makeLink(id: id, name: name)
            }
        case "join":
            guard let id = m["id"] as? String, id != myId else { return }
            makeLink(id: id, name: m["name"] as? String ?? "صديق")
        case "leave":
            guard let id = m["id"] as? String else { return }
            links[id]?.close()
            links[id] = nil
            peers[id] = nil
        case "offer":
            guard let from = m["from"] as? String, let sdp = m["sdp"] as? String else { return }
            if links[from] == nil || links[from]!.hasRemote {
                makeLink(id: from, name: peers[from]?.name ?? "صديق", initiator: false)
            }
            links[from]?.handleOffer(sdp)
        case "answer":
            guard let from = m["from"] as? String, let sdp = m["sdp"] as? String else { return }
            links[from]?.handleAnswer(sdp)
        case "ice":
            guard let from = m["from"] as? String else { return }
            links[from]?.handleIce(m)
        case "chat":
            if let d = m["msg"] as? [String: Any], let msg = Self.decode(d, me: myId) {
                if appendMessage(msg) { notify(msg.name, msg.text ?? "") }
            }
        case "history":
            for d in (m["msgs"] as? [[String: Any]] ?? []) {
                if let msg = Self.decode(d, me: myId) { _ = appendMessage(msg, quiet: true) }
            }
            messages.sort { $0.ts < $1.ts }
            scheduleSave()
        default: break
        }
    }

    private static func decode(_ d: [String: Any], me: String) -> ChatMessage? {
        guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
        let from = d["from"] as? String ?? ""
        return ChatMessage(id: id, from: from, name: d["name"] as? String ?? "صديق",
                           ts: (d["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970,
                           text: text, batch: nil, outgoing: from == me, localRel: nil, status: nil)
    }

    private func makeLink(id: String, name: String, initiator: Bool? = nil) {
        links[id]?.close()
        let isInit = initiator ?? (myId > id)
        let link = PeerLink(
            peerId: id,
            initiator: isInit,
            sendSignal: { [weak self] d in
                var d = d
                d["to"] = id
                self?.sig.send(d)
            },
            makeIncoming: { [weak self] dc in
                IncomingFile(dc: dc, from: id, ev: Self.events(self))
            })
        link.onState = { [weak self] st in
            Task { @MainActor in self?.linkState(id, link, st) }
        }
        links[id] = link
        peers[id] = PeerInfo(id: id, name: name, state: "connecting")
        if isInit { link.makeOffer() }
    }

    private func linkState(_ id: String, _ link: PeerLink, _ st: String) {
        guard links[id] === link else { return }
        peers[id]?.state = st
        if st == "failed" {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.links[id] === link, self.peers[id]?.state == "failed",
                   let name = self.peers[id]?.name {
                    self.makeLink(id: id, name: name)
                }
            }
        }
    }

    // MARK: الدردشة

    func sendText(_ t: String) {
        let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let m = ChatMessage(id: UUID().uuidString, from: myId, name: myName,
                            ts: Date().timeIntervalSince1970, text: text, batch: nil,
                            outgoing: true, localRel: nil, status: nil)
        _ = appendMessage(m, quiet: true)
        sig.send(["type": "chat", "msg": ["id": m.id, "name": myName, "text": text, "ts": m.ts]])
    }

    @discardableResult
    private func appendMessage(_ m: ChatMessage, quiet: Bool = false) -> Bool {
        if messages.contains(where: { $0.id == m.id }) { return false }
        messages.append(m)
        if !quiet { messages.sort { $0.ts < $1.ts } }
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
                st.speed = max(0, Double(bytes - ls.1) / dt)
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
        appendMessage(ChatMessage(id: meta.bid, from: from, name: peers[from]?.name ?? "صديق",
                                  ts: Date().timeIntervalSince1970, text: nil, batch: b,
                                  outgoing: false, localRel: nil, status: "active"))
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
            notify(peers[from]?.name ?? "صديق", "وصلك: \(meta.bname)")
        }
    }

    private func recvFail(_ meta: FileMeta) {
        guard progress[meta.bid]?.finished != true else { return }
        finish(meta.bid, ok: false, note: "انقطع النقل. اطلب منه يعيد الإرسال وبيكمل من نفس المكان.")
    }

    // MARK: الإرسال

    func startSend(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { await runSend(urls) }
    }

    private func runSend(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let listing = Self.listFiles(url)
            if listing.files.isEmpty { showToast("ما لقيت ملفات داخل: \(url.lastPathComponent)"); continue }

            var alive = links.filter { $0.value.isConnected }.map { $0.key }
            if alive.isEmpty { showToast("ما فيه أحد متصل الحين"); return }

            let bid = UUID().uuidString
            let total = listing.files.reduce(Int64(0)) { $0 + $1.size }
            let kind = listing.isFolder ? "folder" : Fmt.kind(of: url.lastPathComponent)
            let batch = BatchInfo(bid: bid, name: url.lastPathComponent, size: total,
                                  count: listing.files.count, isFolder: listing.isFolder, kind: kind)
            appendMessage(ChatMessage(id: bid, from: myId, name: myName,
                                      ts: Date().timeIntervalSince1970, text: nil, batch: batch,
                                      outgoing: true, localRel: nil, status: "active"))
            progress[bid] = TransferState()
            sendTargets[bid] = alive.count
            peerBytes[bid] = [:]
            refreshActivity()

            var base: Int64 = 0
            var doneFiles = 0
            var lostNames: [String] = []

            for f in listing.files {
                let b0 = base
                let meta: [String: Any] = [
                    "bid": bid, "bname": batch.name, "bsize": total, "bcount": batch.count,
                    "folder": batch.isFolder, "kind": kind, "rel": f.rel, "size": f.size,
                ]
                let results: [(String, Bool)] = await withTaskGroup(of: (String, Bool).self) { g in
                    for pid in alive {
                        guard let link = links[pid] else { continue }
                        g.addTask { [weak self] in
                            do {
                                try await link.sendFile(meta: meta, url: f.url, size: UInt64(f.size)) { cur in
                                    Task { @MainActor in self?.sendProgress(bid, pid, b0 + cur) }
                                }
                                return (pid, true)
                            } catch {
                                return (pid, false)
                            }
                        }
                    }
                    var out: [(String, Bool)] = []
                    for await r in g { out.append(r) }
                    return out
                }
                for (pid, ok) in results where !ok {
                    alive.removeAll { $0 == pid }
                    lostNames.append(peers[pid]?.name ?? "صديق")
                }
                if alive.isEmpty { break }
                base += f.size
                doneFiles += 1
                var st = progress[bid] ?? TransferState()
                st.files = doneFiles
                progress[bid] = st
                setBytes(bid, base, force: true)
            }

            if alive.isEmpty {
                finish(bid, ok: false, note: "انقطع الاتصال. أعد الإرسال وبيكمل من نفس المكان.")
            } else {
                finish(bid, ok: true,
                       note: lostNames.isEmpty ? "" : "ما وصل لـ: " + lostNames.joined(separator: "، "))
            }
            let tmp = FileManager.default.temporaryDirectory.path
            if url.path.hasPrefix(tmp) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func sendProgress(_ bid: String, _ pid: String, _ bytes: Int64) {
        peerBytes[bid, default: [:]][pid] = bytes
        let n = Int64(max(1, sendTargets[bid] ?? 1))
        let sum = (peerBytes[bid] ?? [:]).values.reduce(Int64(0), +)
        setBytes(bid, sum / n)
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
        guard let rel = m.localRel else { return nil }
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
