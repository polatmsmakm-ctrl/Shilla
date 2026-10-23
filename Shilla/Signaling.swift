import Foundation

/// اتصال WebSocket بسيرفر الربط (للدردشة وتبادل إشارات الاتصال فقط).
final class Signaling: NSObject {
    var onMessage: (([String: Any]) -> Void)?
    var onStatus: ((Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var url: URL?
    private var hello: [String: Any] = [:]
    private var wanted = false

    func connect(server: String, room: String, id: String, name: String) {
        disconnect()
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        else if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        else if !s.hasPrefix("ws") { s = "wss://" + s }
        guard var comps = URLComponents(string: s) else { return }
        comps.queryItems = [URLQueryItem(name: "room", value: room)]
        guard let u = comps.url else { return }
        url = u
        hello = ["type": "hello", "id": id, "name": name]
        wanted = true
        open()
    }

    func disconnect() {
        wanted = false
        let t = task
        task = nil
        t?.cancel(with: .goingAway, reason: nil)
    }

    private func open() {
        guard wanted, let url else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        send(hello)
        receive(t)
        schedulePing(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(let m):
                self.onStatus?(true)
                var data: Data?
                switch m {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.onMessage?(obj)
                }
                self.receive(t)
            case .failure:
                self.onStatus?(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.wanted, t === self.task else { return }
                    self.open()
                }
            }
        }
    }

    private func schedulePing(_ t: URLSessionWebSocketTask) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, t === self.task else { return }
            t.send(.string("ping")) { _ in }
            self.schedulePing(t)
        }
    }

    func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }
}
