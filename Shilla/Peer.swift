import Foundation
import WebRTC

/// عدد الاتصالات المستقلة لكل صديق. كل اتصال له نافذة ازدحام خاصة (SCTP منفصل)،
/// فمجموعها يعبّي سرعة الخط بدل ما تتشارك كلها نافذة وحدة.
let kLanes = 4
/// أقصى حجم رسالة في WebRTC هو 256KB، نطرح 8 بايت للترويسة
private let kChunk = 262_136
/// أقصى بيانات معلّقة في القناة الوحدة قبل ما ننتظر (حد WebRTC الداخلي 16MB)
private let kMaxBuffered: UInt64 = 6_000_000

/// اتصال مباشر (WebRTC) مع صديق واحد، مكوّن من عدة «حارات» مستقلة.
final class PeerLink: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    let peerId: String
    let initiator: Bool
    /// معرّف هذا الاتصال: أي إشارة من اتصال قديم تنرمي
    let lid: String
    let created = Date()
    var onState: ((String) -> Void)?

    private var pcs: [RTCPeerConnection] = []
    private var ctls: [RTCDataChannel] = []
    private let sendSignal: ([String: Any]) -> Void
    private let makeIncoming: (String) -> IncomingFile
    private var pending: [[RTCIceCandidate]]
    private var remoteSet: [Bool]
    private var laneUp: [Bool]
    private let lock = NSLock()
    private var outs: [ObjectIdentifier: OutgoingFile] = [:]
    private var ins: [String: IncomingFile] = [:]
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    var hasRemote: Bool { lock.lock(); defer { lock.unlock() }; return remoteSet.contains(true) }
    private(set) var isConnected = false
    private(set) var state = "connecting"
    /// كم حارة متصلة الحين (للعرض)
    var lanesUp: Int { lock.lock(); defer { lock.unlock() }; return laneUp.filter { $0 }.count }

    init(peerId: String,
         initiator: Bool,
         lid: String,
         sendSignal: @escaping ([String: Any]) -> Void,
         makeIncoming: @escaping (String) -> IncomingFile) {
        self.peerId = peerId
        self.initiator = initiator
        self.lid = lid
        self.sendSignal = sendSignal
        self.makeIncoming = makeIncoming
        self.pending = Array(repeating: [], count: kLanes)
        self.remoteSet = Array(repeating: false, count: kLanes)
        self.laneUp = Array(repeating: false, count: kLanes)
        super.init()

        let cfg = RTCConfiguration()
        var servers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302",
                                                 "stun:stun1.l.google.com:19302",
                                                 "stun:stun.cloudflare.com:3478"])]
        let d = UserDefaults.standard
        if let t = d.string(forKey: "turnURL"), !t.isEmpty {
            servers.append(RTCIceServer(urlStrings: [t],
                                        username: d.string(forKey: "turnUser") ?? "",
                                        credential: d.string(forKey: "turnPass") ?? ""))
        }
        cfg.iceServers = servers
        cfg.sdpSemantics = .unifiedPlan
        cfg.continualGatheringPolicy = .gatherContinually
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        for _ in 0..<kLanes {
            if let pc = PeerLink.factory.peerConnection(with: cfg, constraints: constraints, delegate: self) {
                pcs.append(pc)
            }
        }
    }

    private func lane(of pc: RTCPeerConnection) -> Int? { pcs.firstIndex { $0 === pc } }

    // MARK: Signaling

    func makeOffer() {
        for (i, pc) in pcs.enumerated() {
            // قناة أولى إجبارية حتى ينفتح SCTP في العرض
            if let c = pc.dataChannel(forLabel: "ctl", configuration: RTCDataChannelConfiguration()) { ctls.append(c) }
            pc.offer(for: constraints) { [weak self] sdp, _ in
                guard let self, let sdp else { return }
                pc.setLocalDescription(sdp) { _ in
                    self.sendSignal(["t": "offer", "sdp": sdp.sdp, "ln": i, "lid": self.lid])
                }
            }
        }
    }

    func handleOffer(lane i: Int, _ sdp: String) {
        guard i >= 0, i < pcs.count else { return }
        let pc = pcs[i]
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] err in
            guard let self, err == nil else { return }
            self.markRemote(i)
            pc.answer(for: self.constraints) { ans, _ in
                guard let ans else { return }
                pc.setLocalDescription(ans) { _ in
                    self.sendSignal(["t": "answer", "sdp": ans.sdp, "ln": i, "lid": self.lid])
                }
            }
        }
    }

    func handleAnswer(lane i: Int, _ sdp: String) {
        guard i >= 0, i < pcs.count else { return }
        pcs[i].setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] err in
            guard err == nil else { return }
            self?.markRemote(i)
        }
    }

    func handleIce(lane i: Int, _ m: [String: Any]) {
        guard i >= 0, i < pcs.count, let sdp = m["candidate"] as? String else { return }
        let line = Int32((m["mline"] as? NSNumber)?.intValue ?? 0)
        let mid = (m["mid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line, sdpMid: mid)
        lock.lock()
        let ready = remoteSet[i]
        if !ready { pending[i].append(cand) }
        lock.unlock()
        if ready { pcs[i].add(cand) { _ in } }
    }

    private func markRemote(_ i: Int) {
        lock.lock()
        remoteSet[i] = true
        let p = pending[i]
        pending[i] = []
        lock.unlock()
        p.forEach { pcs[i].add($0) { _ in } }
    }

    // MARK: Files

    func sendFile(meta: [String: Any], url: URL, size: UInt64,
                  onProgress: @escaping (Int64) -> Void) async throws {
        let tid = UUID().uuidString
        var dcs: [RTCDataChannel] = []
        lock.lock(); let up = laneUp; lock.unlock()
        // القناة رقم 0 (التحكم) دائماً على الحارة 0، والباقي على كل حارة شغالة
        for (i, pc) in pcs.enumerated() where i == 0 || up[i] {
            let cfg = RTCDataChannelConfiguration()
            cfg.isOrdered = false // بدون انتظار ترتيب = أسرع
            guard let dc = pc.dataChannel(forLabel: "f:\(tid):\(i)", configuration: cfg) else {
                if i == 0 { throw TErr.closed } else { continue }
            }
            dcs.append(dc)
        }
        let out = OutgoingFile(dcs: dcs)
        let key = ObjectIdentifier(out)
        lock.lock(); outs[key] = out; lock.unlock()
        defer {
            lock.lock(); outs[key] = nil; lock.unlock()
            dcs.forEach { $0.close() }
        }
        var m = meta
        m["tid"] = tid
        try await out.run(meta: m, url: url, size: size, onProgress: onProgress)
    }

    func close() {
        lock.lock()
        let o = Array(outs.values)
        let i = Array(ins.values)
        lock.unlock()
        o.forEach { $0.abort() }
        i.forEach { $0.abort() }
        pcs.forEach { $0.close() }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard let i = lane(of: peerConnection) else { return }
        let up = (newState == .connected || newState == .completed)
        lock.lock(); laneUp[i] = up; lock.unlock()
        // حالة الاتصال كله = حالة الحارة 0 (عليها قناة التحكم)
        guard i == 0 else { return }
        let s: String
        switch newState {
        case .connected, .completed: s = "connected"
        case .disconnected: s = "weak"
        case .failed: s = "failed"
        case .closed: s = "closed"
        default: s = "connecting"
        }
        state = s
        isConnected = (s == "connected")
        if s == "failed" || s == "closed" {
            lock.lock()
            let o = Array(outs.values)
            let ii = Array(ins.values)
            lock.unlock()
            o.forEach { $0.abort() }
            ii.forEach { $0.abort() }
        }
        onState?(s)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let i = lane(of: peerConnection) else { return }
        sendSignal(["t": "ice",
                    "candidate": candidate.sdp,
                    "mline": Int(candidate.sdpMLineIndex),
                    "mid": candidate.sdpMid ?? "",
                    "ln": i, "lid": lid])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        let parts = dataChannel.label.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "f" else { return }
        let tid = parts[1]
        lock.lock()
        let inc: IncomingFile
        if let e = ins[tid] {
            inc = e
        } else {
            inc = makeIncoming(tid)
            inc.onClosed = { [weak self] in
                self?.lock.lock(); self?.ins[tid] = nil; self?.lock.unlock()
            }
            ins[tid] = inc
        }
        lock.unlock()
        // الربط لازم يكون فوري حتى ما تضيع أول رسالة
        inc.attach(dataChannel)
    }
}

// MARK: - المُرسِل لملف واحد (عدة قنوات متوازية)

enum OutEvent {
    case open
    case text(String)
    case closed
}

final class OutgoingFile: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    let dcs: [RTCDataChannel]
    private let stream: AsyncStream<OutEvent>
    private let cont: AsyncStream<OutEvent>.Continuation

    init(dcs: [RTCDataChannel]) {
        self.dcs = dcs
        var c: AsyncStream<OutEvent>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.cont = c
        super.init()
        dcs.forEach { $0.delegate = self }
    }

    private var ctl: RTCDataChannel { dcs[0] }

    func abort() {
        cont.yield(.closed)
        cont.finish()
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel === ctl else { return }
        switch dataChannel.readyState {
        case .open: cont.yield(.open)
        case .closing, .closed: cont.yield(.closed)
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel === ctl else { return }
        if !buffer.isBinary, let s = String(data: buffer.data, encoding: .utf8) {
            cont.yield(.text(s))
        }
    }

    func run(meta: [String: Any], url: URL, size: UInt64,
             onProgress: @escaping (Int64) -> Void) async throws {
        var it = stream.makeAsyncIterator()

        if ctl.readyState != .open {
            var opened = false
            while let ev = await it.next() {
                if case .open = ev { opened = true; break }
                if case .closed = ev { throw TErr.closed }
            }
            if !opened { throw TErr.closed }
        }

        let metaData = try JSONSerialization.data(withJSONObject: meta)
        guard ctl.sendData(RTCDataBuffer(data: metaData, isBinary: false)) else { throw TErr.closed }

        // المستقبِل يرد بالمكان اللي وصل له (للاستكمال)
        var offset: UInt64 = 0
        var gotOffset = false
        while let ev = await it.next() {
            if case .text(let s) = ev,
               let d = s.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let o = j["offset"] as? NSNumber {
                offset = o.uint64Value
                gotOffset = true
                break
            }
            if case .closed = ev { throw TErr.closed }
        }
        if !gotOffset { throw TErr.closed }

        if offset < size {
            try await pump(url: url, offset: offset, size: size, onProgress: onProgress)
        }

        var okSeen = false
        while let ev = await it.next() {
            if case .text(let s) = ev, s.contains("\"ok\"") { okSeen = true; break }
            if case .closed = ev { throw TErr.closed }
        }
        if !okSeen { throw TErr.closed }
        onProgress(Int64(size))
    }

    private func pickChannel() -> RTCDataChannel? {
        var best: RTCDataChannel?
        var bestBuf = UInt64.max
        for c in dcs where c.readyState == .open {
            let b = c.bufferedAmount
            if b < bestBuf { best = c; bestBuf = b }
        }
        if let b = best, bestBuf < kMaxBuffered { return b }
        return nil
    }

    private func totalBuffered() -> UInt64 {
        dcs.reduce(UInt64(0)) { $0 + $1.bufferedAmount }
    }

    private func pump(url: URL, offset: UInt64, size: UInt64,
                      onProgress: @escaping (Int64) -> Void) async throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        var sent = offset
        var lastReport = Date.distantPast
        while sent < size {
            if Task.isCancelled || ctl.readyState != .open { throw TErr.closed }
            guard let block = try h.read(upToCount: 4 << 20), !block.isEmpty else { break }
            var i = 0
            while i < block.count {
                let end = min(i + kChunk, block.count)
                var frame = Data(capacity: 8 + (end - i))
                var be = (sent + UInt64(i)).bigEndian
                withUnsafeBytes(of: &be) { frame.append(contentsOf: $0) }
                frame.append(block.subdata(in: i..<end))
                while true {
                    if ctl.readyState != .open { throw TErr.closed }
                    if let ch = pickChannel() {
                        if !ch.sendData(RTCDataBuffer(data: frame, isBinary: true)) { throw TErr.closed }
                        break
                    }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                i = end
            }
            sent += UInt64(block.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.12 {
                lastReport = now
                let inflight = totalBuffered()
                let confirmed = sent > inflight ? sent - inflight : 0
                onProgress(Int64(confirmed))
            }
        }
    }
}
