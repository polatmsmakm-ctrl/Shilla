import Foundation

/// عميل MQTT 3.1.1 بسيط فوق WebSocket. نستخدمه مع سيرفرات عامة مجانية
/// (EMQX / HiveMQ / Mosquitto) كقناة للدردشة وتبادل إشارات الاتصال. كل الرسائل مشفّرة.
final class MQTTClient: NSObject {
    var onMessage: ((String, Data) -> Void)?
    var onState: ((Bool) -> Void)?
    var onConnected: (() -> Void)?

    private let q = DispatchQueue(label: "shilla.mqtt")
    private let brokers = [
        "wss://broker.emqx.io:8084/mqtt",
        "wss://broker.hivemq.com:8884/mqtt",
        "wss://test.mosquitto.org:8081/mqtt",
    ]
    private let session = URLSession(configuration: .default)

    private var task: URLSessionWebSocketTask?
    private var brokerIndex = 0
    private var wanted = false
    private var connected = false
    private var clientId = ""
    private var willTopic = ""
    private var willPayload = Data()
    private var subs = Set<String>()
    private var queued: [(String, Data, Bool)] = []
    private var buffer: [UInt8] = []
    private var packetId: UInt16 = 0

    // MARK: واجهة

    func connect(clientId: String, willTopic: String, willPayload: Data) {
        q.async {
            self.clientId = clientId
            self.willTopic = willTopic
            self.willPayload = willPayload
            self.wanted = true
            if self.task == nil { self.open() }
        }
    }

    func disconnect() {
        q.async {
            self.wanted = false
            self.send(Data([0xE0, 0x00]))
            let t = self.task
            self.task = nil
            self.connected = false
            t?.cancel(with: .goingAway, reason: nil)
        }
    }

    /// اشتراك (يُعاد تلقائياً بعد كل اتصال)
    func subscribe(_ topic: String) {
        q.async {
            let isNew = self.subs.insert(topic).inserted
            if isNew && self.connected { self.sendSubscribe(topic) }
        }
    }

    func publish(topic: String, payload: Data, retain: Bool = false) {
        q.async {
            if self.connected {
                self.sendPublish(topic, payload, retain)
            } else {
                if self.queued.count > 300 { self.queued.removeFirst() }
                self.queued.append((topic, payload, retain))
            }
        }
    }

    // MARK: داخلي (كله على الطابور q)

    private func open() {
        guard wanted else { return }
        buffer = []
        connected = false
        guard let url = URL(string: brokers[brokerIndex % brokers.count]) else { return }
        let t = session.webSocketTask(with: url, protocols: ["mqtt"])
        task = t
        t.resume()
        sendConnect()
        receive(t)
        q.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.task === t, !self.connected else { return }
            self.fail(t)
        }
        schedulePing(t)
    }

    private func fail(_ t: URLSessionWebSocketTask) {
        guard task === t else { return }
        let was = connected
        task = nil
        connected = false
        t.cancel(with: .goingAway, reason: nil)
        if was { onState?(false) }
        brokerIndex += 1
        q.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wanted, self.task == nil else { return }
            self.open()
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard self.task === t else { return }
                switch result {
                case .success(let m):
                    switch m {
                    case .data(let d): self.buffer.append(contentsOf: [UInt8](d))
                    case .string(let s): self.buffer.append(contentsOf: [UInt8](s.utf8))
                    @unknown default: break
                    }
                    self.parse()
                    self.receive(t)
                case .failure:
                    self.fail(t)
                }
            }
        }
    }

    private func schedulePing(_ t: URLSessionWebSocketTask) {
        q.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.task === t else { return }
            if self.connected { self.send(Data([0xC0, 0x00])) }
            self.schedulePing(t)
        }
    }

    private func parse() {
        while buffer.count >= 2 {
            // طول الباقي (متغيّر)
            var mult = 1, len = 0, idx = 1
            var complete = false
            while idx < buffer.count && idx <= 4 {
                let b = Int(buffer[idx])
                len += (b & 0x7F) * mult
                mult *= 128
                idx += 1
                if b & 0x80 == 0 { complete = true; break }
            }
            guard complete, buffer.count >= idx + len else { return }
            let first = buffer[0]
            let body = Array(buffer[idx..<(idx + len)])
            buffer.removeFirst(idx + len)
            handle(first, body)
        }
    }

    private func handle(_ first: UInt8, _ body: [UInt8]) {
        switch first >> 4 {
        case 2: // CONNACK
            if body.count >= 2, body[1] == 0 {
                connected = true
                onState?(true)
                for s in subs { sendSubscribe(s) }
                let pending = queued
                queued = []
                for (t, p, r) in pending { sendPublish(t, p, r) }
                onConnected?()
            } else if let t = task {
                fail(t)
            }
        case 3: // PUBLISH
            let qos = Int((first >> 1) & 3)
            guard body.count >= 2 else { return }
            let tl = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + tl else { return }
            let topic = String(decoding: body[2..<(2 + tl)], as: UTF8.self)
            var i = 2 + tl
            var pid: [UInt8] = []
            if qos > 0 {
                guard body.count >= i + 2 else { return }
                pid = [body[i], body[i + 1]]
                i += 2
            }
            let payload = Data(body[i...])
            if qos == 1 { send(Data([0x40, 0x02] + pid)) }
            onMessage?(topic, payload)
        default: break
        }
    }

    // MARK: بناء الحزم

    private func utf(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }

    private func remLen(_ n: Int) -> [UInt8] {
        var x = n
        var out: [UInt8] = []
        repeat {
            var d = UInt8(x % 128)
            x /= 128
            if x > 0 { d |= 0x80 }
            out.append(d)
        } while x > 0
        return out
    }

    private func nextId() -> UInt16 {
        packetId = packetId &+ 1
        if packetId == 0 { packetId = 1 }
        return packetId
    }

    private func send(_ d: Data) {
        task?.send(.data(d)) { _ in }
    }

    private func sendConnect() {
        // نظافة الجلسة = 0 (حتى تتخزن الرسائل وقت الأوفلاين) + رسالة وصية (will) بقيمة الحضور
        let flags: UInt8 = 0x04 | 0x08 | 0x20
        var vh: [UInt8] = utf("MQTT") + [4, flags, 0, 30]
        var pl: [UInt8] = utf(clientId) + utf(willTopic)
        pl += [UInt8(willPayload.count >> 8), UInt8(willPayload.count & 0xFF)] + [UInt8](willPayload)
        vh += pl
        send(Data([0x10] + remLen(vh.count) + vh))
    }

    private func sendSubscribe(_ topic: String) {
        let id = nextId()
        let body: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)] + utf(topic) + [1]
        send(Data([0x82] + remLen(body.count) + body))
    }

    private func sendPublish(_ topic: String, _ payload: Data, _ retain: Bool) {
        let id = nextId()
        var body: [UInt8] = utf(topic)
        body += [UInt8(id >> 8), UInt8(id & 0xFF)]
        body += [UInt8](payload)
        let header: UInt8 = 0x30 | (1 << 1) | (retain ? 1 : 0)
        send(Data([header] + remLen(body.count) + body))
    }
}
