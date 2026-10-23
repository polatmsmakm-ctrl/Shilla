import Foundation

/// عميل الوسيط السحابي (Cloudflare Worker + R2) لإرسال الملفات لصديق غير متصل.
enum Relay {
    static var base: String {
        let o = UserDefaults.standard.string(forKey: "relayURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = o.isEmpty ? Secrets.relay : o
        return b.hasSuffix("/") ? String(b.dropLast()) : b
    }
    static var configured: Bool { URL(string: base)?.host != nil }

    static let partSize = 16 * 1024 * 1024
    static let getChunk: Int64 = 32 * 1024 * 1024

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.waitsForConnectivity = true
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    struct Fail: Error, LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private static func req(_ path: String, _ method: String, _ items: [String: String]) -> URLRequest {
        var c = URLComponents(string: base + path)!
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue(Secrets.key, forHTTPHeaderField: "x-key")
        return r
    }

    private static func check(_ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { throw Fail(msg: "رد غير صحيح") }
        guard h.statusCode == 200 else { throw Fail(msg: "الخدمة ردّت \(h.statusCode)") }
    }

    private static func retry<T>(_ n: Int = 5, _ op: () async throws -> T) async throws -> T {
        var last: Error = Fail(msg: "فشل")
        for i in 0..<n {
            do { return try await op() } catch {
                last = error
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (i + 1)))
            }
        }
        throw last
    }

    // MARK: رفع

    static func put(key: String, data: Data) async throws {
        try await retry {
            let (_, resp) = try await session.upload(for: req("/put", "PUT", ["k": key]), from: data)
            try check(resp)
        }
    }

    private final class Acc: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int64 = 0
        func add(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; v += n; return v }
    }

    static func upload(url: URL, size: Int64, key: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if size == 0 { try await put(key: key, data: Data()); return }

        let created: String = try await retry {
            let (d, resp) = try await session.data(for: req("/create", "POST", ["k": key]))
            try check(resp)
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = j["id"] as? String else { throw Fail(msg: "ما قدرت أبدأ الرفع") }
            return id
        }

        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let acc = Acc()
        var parts: [(Int, String)] = []

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var n = 0
            var running = 0
            var off: Int64 = 0
            while off < size {
                guard let data = try h.read(upToCount: partSize), !data.isEmpty else { break }
                n += 1
                let pn = n
                off += Int64(data.count)
                group.addTask {
                    let etag: String = try await retry {
                        let (d, resp) = try await session.upload(
                            for: req("/part", "PUT", ["k": key, "id": created, "n": String(pn)]), from: data)
                        try check(resp)
                        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let e = j["etag"] as? String else { throw Fail(msg: "رد ناقص") }
                        return e
                    }
                    progress(acc.add(Int64(data.count)))
                    return (pn, etag)
                }
                running += 1
                if running >= 3, let r = try await group.next() { parts.append(r); running -= 1 }
            }
            for try await r in group { parts.append(r) }
        }

        let body = parts.sorted { $0.0 < $1.0 }.map { ["partNumber": $0.0, "etag": $0.1] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: body)
        try await retry {
            var r = req("/done", "POST", ["k": key, "id": created])
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            let (_, resp) = try await session.upload(for: r, from: data)
            try check(resp)
        }
    }

    // MARK: تنزيل

    static func getData(key: String) async throws -> Data {
        try await retry {
            let (d, resp) = try await session.data(for: req("/get", "GET", ["k": key]))
            try check(resp)
            return d
        }
    }

    /// ينزّل على دفعات ويكمل من حجم ملف .part لو انقطع.
    static func download(key: String, to part: URL, total: Int64, progress: @escaping (Int64) -> Void) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let h = try FileHandle(forWritingTo: part)
        defer { try? h.close() }
        var off = try h.seekToEnd()
        if Int64(off) > total { try h.truncate(atOffset: 0); off = 0 }
        progress(Int64(off))

        while Int64(off) < total {
            let len = min(getChunk, total - Int64(off))
            let start = off
            try await retry {
                let (tmp, resp) = try await session.download(
                    for: req("/get", "GET", ["k": key, "s": String(start), "l": String(len)]))
                defer { try? fm.removeItem(at: tmp) }
                try check(resp)
                let got = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? -1
                guard got == len else { throw Fail(msg: "حجم ناقص") }
                let r = try FileHandle(forReadingFrom: tmp)
                defer { try? r.close() }
                try h.seek(toOffset: start)
                while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try h.write(contentsOf: chunk)
                }
            }
            off += UInt64(len)
            progress(Int64(off))
        }
    }

    static func delete(key: String) async {
        _ = try? await session.data(for: req("/del", "DELETE", ["k": key]))
    }
}
