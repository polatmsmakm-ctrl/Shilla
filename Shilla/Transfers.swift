import Foundation
import WebRTC

/// المستقبِل لملف واحد (يستقبل من عدة قنوات متوازية). يكتب مباشرة على القرص،
/// ويحفظ «علامة تقدّم» حتى لو انقطع النقل يكمل من نفس المكان.
final class IncomingFile: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    let tid: String
    private let from: String
    private let ev: RecvEvents
    private let q = DispatchQueue(label: "shilla.recv")
    private let lock = NSLock()
    private var chans: [RTCDataChannel] = []

    var onClosed: (() -> Void)?

    private var meta: FileMeta?
    private var ctl: RTCDataChannel?
    private var handle: FileHandle?
    private var partURL: URL?
    private var wmURL: URL?
    private var finalURL: URL?
    private var startOffset: Int64 = 0
    private var gotBytes: Int64 = 0
    private var wm: Int64 = 0            // كل شي قبل هذا الرقم وصل كامل
    private var lastPersisted: Int64 = 0
    private var pendingChunks: [Int64: Int64] = [:]
    private var finished = false
    private var lastReport = Date.distantPast

    init(tid: String, from: String, ev: RecvEvents) {
        self.tid = tid
        self.from = from
        self.ev = ev
        super.init()
    }

    func attach(_ dc: RTCDataChannel) {
        lock.lock(); chans.append(dc); lock.unlock()
        dc.delegate = self
    }

    func abort() {
        q.async { self.failIfNeeded() }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed {
            q.async {
                // قفل قناة قبل ما يكتمل الملف = فشل
                if !self.finished { self.failIfNeeded() }
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        let bin = buffer.isBinary
        q.async {
            if bin { self.onBinary(data) } else { self.onText(data, dataChannel) }
        }
    }

    // MARK: داخل الطابور التسلسلي

    private func persistWatermark() {
        guard let u = wmURL else { return }
        try? String(wm).write(to: u, atomically: true, encoding: .utf8)
        lastPersisted = wm
    }

    private func failIfNeeded() {
        guard !finished else { return }
        finished = true
        if meta != nil { persistWatermark() }
        try? handle?.close()
        handle = nil
        if let m = meta { ev.onFail(m, from) }
        onClosed?()
    }

    private func reply(_ obj: [String: Any]) {
        guard let c = ctl, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        _ = c.sendData(RTCDataBuffer(data: d, isBinary: false))
    }

    private func onText(_ data: Data, _ channel: RTCDataChannel) {
        guard meta == nil,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = FileMeta(j) else { return }
        meta = m
        ctl = channel

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
        let wmFile = dest.appendingPathExtension("wm")
        partURL = part
        wmURL = wmFile

        // استكمال: نقرأ علامة التقدّم المحفوظة
        var offset: Int64 = 0
        if fm.fileExists(atPath: part.path) {
            if let s = try? String(contentsOf: wmFile, encoding: .utf8), let v = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let psize = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.flatMap { $0.int64Value } ?? 0
                if v >= 0 && v <= m.size && v <= psize { offset = v }
            }
        } else {
            fm.createFile(atPath: part.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: part) else { failIfNeeded(); return }
        handle = h
        startOffset = offset
        wm = offset
        lastPersisted = offset

        ev.onStart(m, from)
        ev.onProgress(m, from, offset)
        reply(["offset": offset])
        if wm >= m.size { complete(top: topName(dest), alreadyThere: false) }
    }

    private func advance(_ off: Int64, _ len: Int64) {
        if off == wm {
            wm += len
            while let l = pendingChunks.removeValue(forKey: wm) { wm += l }
        } else if off > wm {
            pendingChunks[off] = len
        }
    }

    private func onBinary(_ data: Data) {
        guard let m = meta, let h = handle, !finished, data.count > 8 else { return }
        var off: UInt64 = 0
        for b in data.prefix(8) { off = (off << 8) | UInt64(b) }
        let payload = data.dropFirst(8)
        do {
            try h.seek(toOffset: off)
            try h.write(contentsOf: payload)
        } catch {
            failIfNeeded()
            return
        }
        gotBytes += Int64(payload.count)
        advance(Int64(off), Int64(payload.count))

        if wm >= m.size {
            ev.onProgress(m, from, m.size)
            complete(top: topName(finalURL), alreadyThere: false)
            return
        }
        if wm - lastPersisted >= 32 * 1024 * 1024 { persistWatermark() }
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.15 {
            lastReport = now
            ev.onProgress(m, from, min(m.size, startOffset + gotBytes))
        }
    }

    private func complete(top: String, alreadyThere: Bool) {
        guard let m = meta, !finished else { return }
        finished = true
        if !alreadyThere {
            try? handle?.truncate(atOffset: UInt64(m.size))
        }
        try? handle?.close()
        handle = nil
        if !alreadyThere, let part = partURL, let fin = finalURL {
            let fm = FileManager.default
            try? fm.removeItem(at: fin)
            try? fm.moveItem(at: part, to: fin)
            if let w = wmURL { try? fm.removeItem(at: w) }
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
