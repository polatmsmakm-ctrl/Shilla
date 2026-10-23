import Foundation
import CryptoKit

/// تشفير كل الرسائل (دردشة وإشارات اتصال) قبل ما تمر على السيرفر العام.
enum Crypt {
    private static let key = SymmetricKey(data: Data(SHA256.hash(data: Data(("shilla-v2|" + Secrets.key).utf8))))

    static func seal(_ obj: [String: Any]) -> Data? {
        guard let plain = try? JSONSerialization.data(withJSONObject: obj),
              let box = try? AES.GCM.seal(plain, using: key) else { return nil }
        return box.combined
    }

    static func open(_ data: Data) -> [String: Any]? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }
}
