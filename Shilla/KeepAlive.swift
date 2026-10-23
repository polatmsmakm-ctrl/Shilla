import AVFoundation

/// يشغّل صوتاً صامتاً حتى يبقى التطبيق شغّال بالخلفية أثناء النقل.
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?
    private var observing = false

    func set(_ on: Bool) {
        if on {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, options: [.mixWithOthers])
            try? s.setActive(true)
            if player == nil, let p = try? AVAudioPlayer(data: Self.silence()) {
                p.numberOfLoops = -1
                p.volume = 0.01
                p.prepareToPlay()
                player = p
            }
            player?.play()
            if !observing {
                observing = true
                NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self?.player?.play()
                }
            }
        } else {
            player?.stop()
            player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func silence() -> Data {
        let rate: UInt32 = 8000
        let samples = Int(rate) // ثانية واحدة
        let dataSize = UInt32(samples * 2)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
