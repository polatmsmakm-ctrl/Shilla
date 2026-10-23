import Foundation

struct BatchInfo: Codable, Hashable {
    var bid: String
    var name: String
    var size: Int64
    var count: Int
    var isFolder: Bool
    var kind: String // video, image, file, folder
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: String
    var from: String
    var name: String
    var ts: Double
    var text: String?
    var batch: BatchInfo?
    var outgoing: Bool
    var localRel: String?   // مسار العنصر المستلم نسبةً لمجلد Documents
    var status: String?     // active / done / failed
}

struct TransferState: Hashable {
    var bytes: Int64 = 0
    var files: Int = 0
    var speed: Double = 0
    var finished = false
    var failed = false
    var note = ""
}

struct PeerInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var state: String // connecting / connected / weak / failed / closed
}

struct FileMeta {
    var bid: String
    var bname: String
    var bsize: Int64
    var bcount: Int
    var isFolder: Bool
    var kind: String
    var rel: String
    var size: Int64

    init?(_ j: [String: Any]) {
        guard let bid = j["bid"] as? String,
              let bname = j["bname"] as? String,
              let rel = j["rel"] as? String else { return nil }
        self.bid = bid
        self.bname = bname
        self.rel = rel
        self.bsize = (j["bsize"] as? NSNumber)?.int64Value ?? 0
        self.bcount = (j["bcount"] as? NSNumber)?.intValue ?? 1
        self.isFolder = (j["folder"] as? NSNumber)?.boolValue ?? false
        self.kind = j["kind"] as? String ?? "file"
        self.size = (j["size"] as? NSNumber)?.int64Value ?? 0
    }
}

struct RecvEvents {
    var onStart: (FileMeta, String) -> Void
    var onProgress: (FileMeta, String, Int64) -> Void
    var onFinish: (FileMeta, String, String) -> Void
    var onFail: (FileMeta, String) -> Void
}

enum TErr: Error { case closed }

enum Fmt {
    static func size(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
    static func kind(of name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "hevc", "avi", "mkv", "3gp"].contains(e) { return "video" }
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "tiff"].contains(e) { return "image" }
        return "file"
    }
}

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var received: URL {
        let u = documents.appendingPathComponent("Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var messagesFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messages.json")
    }
}
