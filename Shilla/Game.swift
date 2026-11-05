import SwiftUI

/// لعبة Jelly Jump: لعبة جري بسيطة تشتغل فعلاً (اضغط للقفز، تجنّب الشجيرات، اجمع العملات).
/// السر: ضغطة مطوّلة على الغيمة الكبيرة 3.5 ثانية = يفتح البرنامج.
final class JellyGame {
    static let holdSeconds: Double = 3.5

    enum Phase { case ready, play, over }
    struct Obstacle { var x: CGFloat; var w: CGFloat; var h: CGFloat }
    struct Coin { var x: CGFloat; var y: CGFloat; var got = false }

    var phase: Phase = .ready
    var size: CGSize = .zero
    var t: Double = 0
    var speed: CGFloat = 330
    var score: Double = 0
    var coins = 0
    var best: Int = UserDefaults.standard.integer(forKey: "jj_best")
    var y: CGFloat = 0
    var vy: CGFloat = 0
    var squash: CGFloat = 0
    var obs: [Obstacle] = []
    var coinList: [Coin] = []
    var spawnIn: Double = 1.2
    var coinIn: Double = 0.8
    var groundOff: CGFloat = 0
    var lastTick: Date?

    // الغيمة السرية
    var cloudCenter: CGPoint = .zero
    var cloudR: CGFloat = 50
    var holdStart: Date?

    var groundY: CGFloat { size.height - max(90, size.height * 0.16) }
    var jellyR: CGFloat { max(24, min(size.width, size.height) * 0.07) }
    var jellyX: CGFloat { max(70, size.width * 0.22) }

    func inCloud(_ p: CGPoint) -> Bool {
        let dx = (p.x - cloudCenter.x) / (cloudR * 1.7)
        let dy = (p.y - cloudCenter.y) / (cloudR * 1.0)
        return dx * dx + dy * dy <= 1
    }

    func reset() {
        phase = .play; t = 0; speed = 330; score = 0; coins = 0
        y = 0; vy = 0; obs = []; coinList = []; spawnIn = 1.0; coinIn = 0.6
    }

    func jump() {
        guard phase == .play else { reset(); return }
        if y <= 0.5 { vy = 820; squash = -0.25 }
    }

    /// يرجع true لو خلصت الضغطة المطوّلة على الغيمة
    func tick(_ now: Date) -> Bool {
        let dt = min(0.05, now.timeIntervalSince(lastTick ?? now))
        lastTick = now
        cloudR = max(42, min(size.width, size.height) * 0.11)
        cloudCenter = CGPoint(x: size.width * 0.68,
                              y: size.height * 0.2 + CGFloat(sin(now.timeIntervalSince1970 / 1.4)) * 6)
        if let h = holdStart, now.timeIntervalSince(h) >= Self.holdSeconds {
            holdStart = nil
            return true
        }
        squash *= CGFloat(pow(0.001, dt))
        guard phase == .play, size.width > 0 else { return false }
        t += dt
        speed = 330 + CGFloat(min(420, t * 9))
        score += dt * Double(speed) / 40
        groundOff = (groundOff + speed * CGFloat(dt)).truncatingRemainder(dividingBy: 64)

        vy -= 2300 * CGFloat(dt)
        y = max(0, y + vy * CGFloat(dt))
        if y == 0 && vy < 0 { if vy < -300 { squash = 0.3 }; vy = 0 }

        spawnIn -= dt
        if spawnIn <= 0 {
            let tall = Double.random(in: 0...1) < 0.35
            obs.append(Obstacle(x: size.width + 40, w: tall ? 32 : 44, h: tall ? 66 : 40))
            spawnIn = 0.9 + Double.random(in: 0...1.1) - min(0.4, t * 0.006)
        }
        coinIn -= dt
        if coinIn <= 0 {
            coinList.append(Coin(x: size.width + 30, y: CGFloat.random(in: 60...170)))
            coinIn = 0.7 + Double.random(in: 0...1.2)
        }
        for i in obs.indices { obs[i].x -= speed * CGFloat(dt) }
        for i in coinList.indices { coinList[i].x -= speed * CGFloat(dt) }
        obs.removeAll { $0.x < -80 }
        coinList.removeAll { $0.x < -40 || $0.got }

        let jr = jellyR, jx = jellyX, jy = groundY - jr - y
        for o in obs {
            let top = groundY - o.h
            let cx = max(o.x, min(jx, o.x + o.w))
            let cy = max(top, min(jy, groundY))
            if pow(jx - cx, 2) + pow(jy - cy, 2) < pow(jr * 0.82, 2) {
                phase = .over
                let s = Int(score)
                if s > best { best = s; UserDefaults.standard.set(best, forKey: "jj_best") }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
        for i in coinList.indices {
            let cy = groundY - coinList[i].y
            if pow(jx - coinList[i].x, 2) + pow(jy - cy, 2) < pow(jr + 16, 2) {
                coinList[i].got = true
                coins += 1
                score += 25
            }
        }
        return false
    }

    // MARK: الرسم

    func draw(_ ctx: inout GraphicsContext) {
        let W = size.width, H = size.height
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0xFF9640), location: 0),
                             .init(color: Color(hex: 0xC8608A), location: 0.55),
                             .init(color: Color(hex: 0x7A3CC8), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [Color(hex: 0xFFEB96).opacity(0.85), Color(hex: 0xFFEB96).opacity(0)]),
            center: CGPoint(x: W * 0.78, y: H * 0.3), startRadius: 10, endRadius: H * 0.42))

        drawCloud(&ctx, cloudCenter, cloudR)

        let gy = groundY
        ctx.fill(Path(ellipseIn: CGRect(x: W * 0.18 - W * 0.55, y: gy - H * 0.2, width: W * 1.1, height: H * 0.5)),
                 with: .color(Color(hex: 0x2EAA6E)))
        ctx.fill(Path(ellipseIn: CGRect(x: W * 0.85 - W * 0.55, y: gy - H * 0.15, width: W * 1.1, height: H * 0.5)),
                 with: .color(Color(hex: 0x228C5F)))

        var x = -groundOff
        while x < W + 64 {
            ctx.fill(Path(roundedRect: CGRect(x: x + 2, y: gy + 10, width: 60, height: H - gy), cornerRadius: 8),
                     with: .color(Color(hex: 0x8C5028)))
            ctx.fill(Path(roundedRect: CGRect(x: x + 2, y: gy, width: 60, height: 22), cornerRadius: 8),
                     with: .color(Color(hex: 0x5FCD5A)))
            x += 64
        }

        for c in coinList {
            let cy = gy - c.y
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 15, y: cy - 15, width: 30, height: 30)), with: .color(Color(hex: 0xC88200)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 12, y: cy - 13, width: 24, height: 24)), with: .color(Color(hex: 0xFFCD28)))
            ctx.fill(Path(roundedRect: CGRect(x: c.x - 3, y: cy - 8, width: 6, height: 14), cornerRadius: 3), with: .color(Color(hex: 0xFFF09A)))
        }

        for o in obs {
            ctx.fill(Path(roundedRect: CGRect(x: o.x, y: gy - o.h, width: o.w, height: o.h + 4), cornerRadius: 10),
                     with: .color(Color(hex: 0x1F6F3E)))
            for k in 0..<3 {
                let sx = o.x + (o.w / 3) * CGFloat(k)
                var p = Path()
                p.move(to: CGPoint(x: sx, y: gy - o.h + 4))
                p.addLine(to: CGPoint(x: sx + o.w / 6, y: gy - o.h - 12))
                p.addLine(to: CGPoint(x: sx + o.w / 3, y: gy - o.h + 4))
                ctx.fill(p, with: .color(Color(hex: 0x2F9A55)))
            }
        }

        drawJelly(&ctx)

        let big = max(22, H * 0.035)
        ctx.draw(Text("\(Int(score))").font(.system(size: big, weight: .heavy, design: .rounded)).foregroundColor(.white),
                 at: CGPoint(x: 22, y: 70), anchor: .leading)
        ctx.draw(Text("BEST \(best)   🪙 \(coins)").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(.white),
                 at: CGPoint(x: 22, y: 70 + big), anchor: .leading)
        if phase != .play {
            ctx.draw(Text(phase == .over ? "GAME OVER" : "JELLY JUMP")
                        .font(.system(size: max(34, W * 0.1), weight: .black, design: .rounded)).foregroundColor(.white),
                     at: CGPoint(x: W / 2, y: H * 0.42))
            ctx.draw(Text("Tap to jump").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9)),
                     at: CGPoint(x: W / 2, y: H * 0.42 + max(34, W * 0.1)))
        }
    }

    private func drawCloud(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        var p = Path()
        func circ(_ dx: CGFloat, _ dy: CGFloat, _ rr: CGFloat) {
            p.addEllipse(in: CGRect(x: c.x + r * dx - r * rr, y: c.y + r * dy - r * rr, width: 2 * r * rr, height: 2 * r * rr))
        }
        circ(-0.9, 0.15, 0.6); circ(-0.25, -0.25, 0.78); circ(0.55, -0.05, 0.68); circ(1.05, 0.25, 0.48)
        p.addRect(CGRect(x: c.x - r * 0.9, y: c.y + r * 0.1, width: r * 1.95, height: r * 0.6))
        ctx.fill(p, with: .color(.white.opacity(0.95)))
    }

    private func drawJelly(_ ctx: inout GraphicsContext) {
        let jr = jellyR, jx = jellyX, jy = groundY - jr - y
        let sx = 1 + squash, sy = 1 - squash
        var c = ctx
        c.translateBy(x: jx, y: jy + jr * (1 - sy))
        c.scaleBy(x: sx, y: sy)
        func e(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
        }
        c.fill(e(0, jr + y / sy + 2, jr * 0.8, 6), with: .color(Color(hex: 0x143C1E).opacity(0.35)))
        c.fill(e(0, 0, jr, jr), with: .color(Color(hex: 0x781EA0)))
        c.fill(e(0, 0, jr * 0.93, jr * 0.93), with: .color(Color(hex: 0xBE46F0)))
        c.fill(e(-jr * 0.3, -jr * 0.55, jr * 0.32, jr * 0.2), with: .color(Color(hex: 0xF0B4FF).opacity(0.9)))
        for ex: CGFloat in [-0.33, 0.33] {
            c.fill(e(jr * ex, -jr * 0.05, jr * 0.24, jr * 0.28), with: .color(.white))
            c.fill(e(jr * ex + jr * 0.04, jr * 0.02, jr * 0.12, jr * 0.15), with: .color(Color(hex: 0x1E1432)))
        }
        var smile = Path()
        smile.move(to: CGPoint(x: -jr * 0.24, y: jr * 0.38))
        smile.addQuadCurve(to: CGPoint(x: jr * 0.24, y: jr * 0.38), control: CGPoint(x: 0, y: jr * 0.62))
        c.stroke(smile, with: .color(Color(hex: 0x3C0A46)), style: StrokeStyle(lineWidth: jr * 0.08, lineCap: .round))
    }
}

struct GameView: View {
    let onReveal: () -> Void
    @State private var game = JellyGame()
    @State private var touching = false

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    game.size = size
                    if game.tick(tl.date) {
                        DispatchQueue.main.async { onReveal() }
                    }
                    game.draw(&ctx)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        if !touching {
                            touching = true
                            if game.inCloud(v.startLocation) {
                                game.holdStart = Date()
                            } else {
                                game.jump()
                            }
                        } else if game.holdStart != nil && !game.inCloud(v.location) {
                            game.holdStart = nil
                        }
                    }
                    .onEnded { _ in
                        touching = false
                        game.holdStart = nil
                    }
            )
            .onAppear { game.size = geo.size; game.lastTick = nil; if game.phase == .play { game.phase = .ready } }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .environment(\.layoutDirection, .leftToRight)
    }
}
