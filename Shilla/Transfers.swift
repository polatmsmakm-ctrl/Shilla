import Foundation
import WebRTC

/// المستقبِل لملف واحد. يكتب مباشرة على القرص (ما يحمّل الملف في الذاكرة)،
/// ويدعم الاستكمال: لو انقطع النقل يكمل من نفس المكان لما تعيد الإرسال.
final class IncomingFile: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    private let dc: RTCDataChannel
    private let from: String
    private let ev: RecvEvents
    private let q = DispatchQueue(label: "shilla.recv")

    var onClosed: (() -> Void)?

    private var meta: FileMeta?
    private var handle: FileHandle?
    private var partURL: URL?
    private var finalURL: URL?
    private var written: Int64 = 0
    private var finished = false
    private var lastReport = Date.distantPast

    init(dc: RTCDataChannel, from: String, ev: RecvEvents) {
        self.dc = dc
        self.from = from
        self.ev = ev
        super.init()
        dc.delegate = self
    }

    func abort() {
        q.async { self.failIfNeeded() }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed {
            q.async { self.failIfNeeded() }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        let bin = buffer.isBinary
        q.async {
            if bin { self.onBinary(data) } else { self.onText(data) }
        }
    }

    // MARK: داخل الطابور التسلسلي

    private func failIfNeeded() {
        guard !finished else { return }
        finished = true
        try? handle?.close()
        handle = nil
        if let m = meta { ev.onFail(m, from) }
        onClosed?()
    }

    private func reply(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            _ = dc.sendData(RTCDataBuffer(data: d, isBinary: false))
        }
    }

    private func onText(_ data: Data) {
        guard meta == nil,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = FileMeta(j) else { return }
        meta = m

        let fm = FileManager.default
        let comps = m.rel.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        guard !comps.isEmpty else { failIfNeeded(); return }

        var dest = Paths.received
        for c in comps { dest.appendPathComponent(c) }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // لو الملف موجود بنفس الحجم نعتبره مستلم من قبل. لو مختلف نضيف رقم.
        if fm.fileExists(atPath: dest.path) {
            let existing = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.flatMap { $0.int64Value } ?? -1
            if existing == m.size {
                finalURL = dest
                ev.onStart(m, from)
                reply(["offset": m.size])
                complete(top: comps[0], alreadyThere: true)
                return
            }
            dest = Self.unique(dest)
        }
        finalURL = dest
        let part = dest.appendingPathExtension("part")
        partURL = part

        var offset: Int64 = 0
        if fm.fileExists(atPath: part.path) {
            let p = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.flatMap { $0.int64Value } ?? 0
            offset = (p <= m.size) ? p : 0
        } else {
            fm.createFile(atPath: part.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: part) else { failIfNeeded(); return }
        try? h.truncate(atOffset: UInt64(offset))
        try? h.seek(toOffset: UInt64(offset))
        handle = h
        written = offset

        ev.onStart(m, from)
        ev.onProgress(m, from, offset)
        reply(["offset": offset])
        if written >= m.size { complete(top: topName(dest), alreadyThere: false) }
    }

    private func onBinary(_ data: Data) {
        guard let m = meta, let h = handle, !finished else { return }
        do { try h.write(contentsOf: data) } catch { failIfNeeded(); return }
        written += Int64(data.count)
        if written >= m.size {
            ev.onProgress(m, from, m.size)
            complete(top: topName(finalURL), alreadyThere: false)
        } else {
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.15 {
                lastReport = now
                ev.onProgress(m, from, written)
            }
        }
    }

    private func complete(top: String, alreadyThere: Bool) {
        guard let m = meta, !finished else { return }
        finished = true
        try? handle?.close()
        handle = nil
        if !alreadyThere, let part = partURL, let fin = finalURL {
            let fm = FileManager.default
            try? fm.removeItem(at: fin)
            try? fm.moveItem(at: part, to: fin)
        }
        reply(["ok": 1])
        ev.onFinish(m, from, "Received/" + top)
        onClosed?()
    }

    private func topName(_ url: URL?) -> String {
        guard let url else { return "" }
        let base = Paths.received.standardizedFileURL.path
        var p = url.standardizedFileURL.path
        if p.hasPrefix(base) { p = String(p.dropFirst(base.count)) }
        return p.split(separator: "/").first.map(String.init) ?? url.lastPathComponent
    }

    private static func unique(_ url: URL) -> URL {
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
}
