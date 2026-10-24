// The fiery pit: the floor of the screen turns to lava; removed downloads fall into it and burn,
// retried ones burn and then rise back out, resurrected. Drawn in a click-through overlay window
// that only exists while an effect is playing. Everything is computed from timestamps, so the
// scene can also be rendered at any moment for storyboards and tests.
import SwiftUI
import AppKit

enum PitStyle: String, CaseIterable {
    case classic, swat, phoenix, off

    var label: String {
        switch self {
        case .classic: return "Classic drop"
        case .swat: return "Kitty swat"
        case .phoenix: return "Phoenix"
        case .off: return "Off"
        }
    }

    static var current: PitStyle {
        get { PitStyle(rawValue: UserDefaults.standard.string(forKey: "pitStyle") ?? "") ?? .classic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pitStyle") }
    }
}

/// One falling card. Positions are in overlay coordinates (origin top-left of the screen).
struct PitEffect: Identifiable {
    let id = UUID()
    let key: String              // the download's id: the same row can't fall twice at once
    let card: Image
    let size: CGSize
    let start: CGPoint           // card centre when it leaves the row
    let born: Date
    let style: PitStyle
    let resurrect: Bool

    // timeline (seconds after `born`)
    var lead: Double { style == .swat ? 0.35 : 0.12 }         // swat wind-up / little pop
    var fall: Double { style == .phoenix ? 0.8 : 1.0 }
    var land: Double { lead + fall }
    var burnEnd: Double { land + 0.55 }
    var riseEnd: Double { burnEnd + 1.25 }
    var end: Double { (resurrect ? riseEnd : burnEnd) + 0.9 }   // + embers and the pit closing
}

/// Deterministic "random" numbers so particles need no stored state.
private func rnd(_ seed: Int, _ i: Int) -> Double {
    var x = UInt64(bitPattern: Int64(seed &* 2_654_435_761 &+ i &* 40_503))
    x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
    return Double(x % 10_000) / 10_000
}

private let lava1 = Color(red: 1.0, green: 0.86, blue: 0.35)
private let lava2 = Color(red: 1.0, green: 0.45, blue: 0.12)
private let lava3 = Color(red: 0.7, green: 0.1, blue: 0.08)
private let rock = Color(red: 0.16, green: 0.09, blue: 0.1)

@MainActor
final class PitModel: ObservableObject {
    @Published var effects: [PitEffect] = []
}

nonisolated(unsafe) var pitFrames = 0   // frames drawn, for the stress test

struct PitScene: View {
    @ObservedObject var model: PitModel
    var frozenAt: Date? = nil
    var floor: CGFloat = 110             // how high the lava rises from the bottom of the screen

    var body: some View {
        if let at = frozenAt { canvas(at) } else { TimelineView(.animation) { ctx in canvas(ctx.date) } }
    }

    func canvas(_ now: Date) -> some View {
        let effects = model.effects
        let floor = self.floor
        if frozenAt == nil { pitFrames += 1 }
        return Canvas { c, size in
            let t = now.timeIntervalSinceReferenceDate
            PitScene.drawGlow(c, size: size, floor: floor, effects: effects, now: now)
            for e in effects { PitScene.drawCard(c, size: size, floor: floor, effect: e, now: now, t: t) }
            PitScene.drawLava(c, size: size, floor: floor, effects: effects, now: now, t: t)   // in front: cards sink into it
            for e in effects { PitScene.drawSplash(c, size: size, floor: floor, effect: e, now: now, t: t) }
        }
    }

    // MARK: geometry

    static func pitCentre(_ e: PitEffect, size: CGSize, floor: CGFloat) -> CGPoint {
        let y = size.height - floor + 4         // at the surface: half-submerged on impact, then it sinks
        let drift = (rnd(e.id.hashValue & 0xffff, 999) - 0.5) * 120
        let x: Double
        switch e.style {
        case .phoenix: x = e.start.x                    // straight down
        case .swat: x = e.start.x - 260                 // where it was flung
        default: x = e.start.x + drift                  // a little drift
        }
        return CGPoint(x: min(max(x, 120), size.width - 120), y: y)
    }

    /// The lava's surface height at x, rippling, with a bulge where cards splash.
    static func surface(_ x: Double, size: CGSize, floor: CGFloat, o: Double, effects: [PitEffect], now: Date, t: Double) -> Double {
        var y = size.height - floor * o + 7 * sin(x / 70 + t * 1.8) + 4 * sin(x / 31 - t * 2.6)
        for e in effects {
            let s = now.timeIntervalSince(e.born) - e.land
            guard s > -0.1, s < 1.2 else { continue }
            let lx = pitCentre(e, size: size, floor: floor).x
            let d = abs(x - lx)
            y -= 9 * exp(-(d - 90) * (d - 90) / 1500) * max(0, 1 - s / 1.2)   // a ripple ring either side of the splash
        }
        return y
    }

    static func openness(_ e: PitEffect, _ s: Double) -> Double {
        let open = min(1, max(0, s / 0.35))
        let close = min(1, max(0, (e.end - s) / 0.45))
        return smooth(min(open, close))
    }

    static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// Card centre, rotation, scale and how much it's burning, at `s` seconds into the effect.
    static func cardState(_ e: PitEffect, _ s: Double, pit: CGPoint) -> (p: CGPoint, angle: Double, scale: Double, fire: Double, alpha: Double)? {
        let sx = e.start.x, sy = e.start.y
        if s < e.lead {                                            // wind-up
            let k = s / e.lead
            if e.style == .swat {                                  // shudder as the paw hits it
                return (CGPoint(x: sx + 6 * sin(k * 30), y: sy), 0.05 * sin(k * 30), 1, 0, 1)
            }
            return (CGPoint(x: sx, y: sy - 14 * sin(k * .pi / 2)), 0, 1.03, 0, 1)
        }
        if s < e.land {                                            // the fall
            let u = (s - e.lead) / e.fall
            let x: Double, y: Double, angle: Double
            switch e.style {
            case .swat:      // flung sideways and up, then gravity
                x = sx + (pit.x - sx) * (1 - pow(1 - u, 2))
                y = sy - 80 * sin(u * .pi) * (1 - u) + (pit.y - sy) * u * u
                angle = -u * u * 6.5
            case .phoenix:   // straight down, fast
                x = sx + (pit.x - sx) * u
                y = sy - 14 + (pit.y - sy + 14) * u * u
                angle = u * 0.4
            default:
                x = sx + (pit.x - sx) * smooth(u)
                y = sy - 14 + (pit.y - sy + 14) * u * u
                angle = u * u * 2.4
            }
            let fire = e.style == .phoenix ? min(1, u * 1.4) : max(0, (u - 0.75) * 3)
            return (CGPoint(x: x, y: y), angle, 1 - 0.45 * u, fire, 1)
        }
        if s < e.burnEnd {                                         // sinking into the lava, burning away
            let k = (s - e.land) / (e.burnEnd - e.land)
            return (CGPoint(x: pit.x, y: pit.y + 46 * k), 0.3 * k, 0.55 * (1 - 0.3 * k), 0.45 + 0.55 * k, 1 - k * k * k)   // sinks under
        }
        if e.resurrect && s < e.riseEnd {                          // rising again
            let k = (s - e.burnEnd) / (e.riseEnd - e.burnEnd)
            let ease = 1 - pow(1 - k, 3)
            let x = pit.x + (sx - pit.x) * ease, y = pit.y + (sy - pit.y) * ease - 20 * sin(k * .pi)
            let alpha = k < 0.15 ? k / 0.15 : k > 0.8 ? (1 - k) / 0.2 : 1
            return (CGPoint(x: x, y: y), 0.08 * sin(k * 9), 0.6 + 0.4 * ease, 0, alpha)
        }
        return nil
    }

    // MARK: drawing

    static func lavaLevel(_ effects: [PitEffect], now: Date) -> Double {
        effects.map { openness($0, now.timeIntervalSince($0.born)) }.max() ?? 0
    }

    static func drawGlow(_ c: GraphicsContext, size: CGSize, floor: CGFloat, effects: [PitEffect], now: Date) {
        let o = lavaLevel(effects, now: now)
        guard o > 0.01 else { return }
        let top = size.height - floor * o
        c.fill(Path(CGRect(x: 0, y: top - 170, width: size.width, height: 200)),
               with: .linearGradient(Gradient(colors: [lava2.opacity(0), lava2.opacity(0.38 * o)]),
                                     startPoint: CGPoint(x: 0, y: top - 170), endPoint: CGPoint(x: 0, y: top + 30)))
    }

    static func drawLava(_ c: GraphicsContext, size: CGSize, floor: CGFloat, effects: [PitEffect], now: Date, t: Double) {
        let o = lavaLevel(effects, now: now)
        guard o > 0.01 else { return }
        func surf(_ x: Double) -> Double { surface(x, size: size, floor: floor, o: o, effects: effects, now: now, t: t) }
        // the lava body
        var body = Path()
        body.move(to: CGPoint(x: 0, y: size.height))
        for x in stride(from: 0.0, through: size.width + 12, by: 12) { body.addLine(to: CGPoint(x: x, y: surf(x))) }
        body.addLine(to: CGPoint(x: size.width, y: size.height))
        body.closeSubpath()
        let top = size.height - floor * o
        c.fill(body, with: .linearGradient(Gradient(colors: [lava1, lava2, lava3, Color(red: 0.35, green: 0.04, blue: 0.05)]),
                                           startPoint: CGPoint(x: 0, y: top - 10), endPoint: CGPoint(x: 0, y: size.height)))
        // bright crust lines drifting across
        for i in 0..<5 {
            let y0 = top + 18 + Double(i) * floor * 0.15 * o
            var crust = Path()
            for x in stride(from: 0.0, through: size.width, by: 16) {
                let y = y0 + 4 * sin(x / (40 + Double(i) * 9) + t * (0.8 + Double(i) * 0.2))
                x == 0 ? crust.move(to: CGPoint(x: x, y: y)) : crust.addLine(to: CGPoint(x: x, y: y))
            }
            c.stroke(crust, with: .color(lava1.opacity(0.28 * o)), lineWidth: 2)
        }
        // bubbles popping all along the surface
        for i in 0..<Int(size.width / 55) {
            let k = (t * 0.7 + rnd(7, i)).truncatingRemainder(dividingBy: 1)
            let bx = rnd(11, i) * size.width, by = surf(bx) + 14 + rnd(13, i) * 30
            let r = 3 + 6 * sin(k * .pi)
            c.fill(Path(ellipseIn: CGRect(x: bx - r, y: by - r * 0.6, width: 2 * r, height: 1.2 * r)), with: .color(lava1.opacity(0.75 * (1 - k))))
        }
        // flames along the whole surface; they flare up next to a splash
        for i in 0..<Int(size.width / 48) {
            let fx = (Double(i) + 0.5) * 48 + 10 * sin(Double(i) * 1.7)
            var flare = 0.0
            for e in effects {
                let s = now.timeIntervalSince(e.born) - e.land
                guard s > -0.1, s < 1.0 else { continue }
                let d = abs(fx - pitCentre(e, size: size, floor: floor).x)
                flare = max(flare, exp(-d * d / 9000) * max(0, 1 - s))
            }
            let flick = 0.55 + 0.45 * sin(t * (6 + rnd(17, i) * 5) + Double(i))
            let fh = (14 + 20 * rnd(19, i)) * flick * o * (1 + 2.2 * flare)
            let fw = 10 + 8 * rnd(23, i)
            let base = surf(fx) + 3
            var flame = Path()
            flame.move(to: CGPoint(x: fx - fw / 2, y: base))
            flame.addQuadCurve(to: CGPoint(x: fx + 3 * sin(t * 6 + Double(i)), y: base - fh), control: CGPoint(x: fx - fw, y: base - fh * 0.5))
            flame.addQuadCurve(to: CGPoint(x: fx + fw / 2, y: base), control: CGPoint(x: fx + fw, y: base - fh * 0.5))
            c.fill(flame, with: .linearGradient(Gradient(colors: [lava1.opacity(0.95), lava2.opacity(0.85), lava3.opacity(0)]),
                                                startPoint: CGPoint(x: fx, y: base), endPoint: CGPoint(x: fx, y: base - fh)))
        }
    }

    /// Embers and smoke where a card splashed in.
    static func drawSplash(_ c: GraphicsContext, size: CGSize, floor: CGFloat, effect e: PitEffect, now: Date, t: Double) {
        let s = now.timeIntervalSince(e.born)
        guard s > e.land else { return }
        let pit = pitCentre(e, size: size, floor: floor)
        let seed = e.id.hashValue & 0xffff
        let k0 = s - e.land
        for i in 0..<28 {
            let life = 0.9 + rnd(seed, i + 50) * 0.9
            let k = k0 - rnd(seed, i + 60) * 0.4
            guard k > 0, k < life else { continue }
            let vx = (rnd(seed, i + 70) - 0.5) * 160, vy = -(110 + rnd(seed, i + 80) * 190)
            let x = pit.x + vx * k + 8 * sin(k * 7 + Double(i)), y = pit.y - 20 + vy * k + 70 * k * k
            let r = 1.4 + 1.8 * rnd(seed, i + 90)
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                   with: .color((i % 3 == 0 ? lava1 : lava2).opacity(1 - k / life)))
        }
        for i in 0..<5 {
            let k = k0 - Double(i) * 0.08
            guard k > 0, k < 1.6 else { continue }
            let r = 14 + 26 * k
            let x = pit.x + (rnd(seed, i + 100) - 0.5) * 60, y = pit.y - 40 - 70 * k
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                   with: .color(Color(white: 0.3).opacity(0.2 * (1 - k / 1.6))))
        }
    }

    static func drawCard(_ c: GraphicsContext, size: CGSize, floor: CGFloat, effect e: PitEffect, now: Date, t: Double) {
        let s = now.timeIntervalSince(e.born)
        let pit = pitCentre(e, size: size, floor: floor)
        guard let st = cardState(e, s, pit: pit), st.alpha > 0.01 else { return }
        let seed = e.id.hashValue & 0xffff
        let rising = e.resurrect && s >= e.burnEnd

        // phoenix ember trail while falling
        if e.style == .phoenix && st.fire > 0.2 && s < e.land {
            for i in 0..<10 {
                let back = Double(i) * 0.03
                let p2 = cardState(e, max(e.lead, s - back), pit: pit)?.p ?? st.p
                let r = 2.5 * (1 - Double(i) / 10)
                c.fill(Path(ellipseIn: CGRect(x: p2.x - r + (rnd(seed, i) - 0.5) * 18, y: p2.y - r - 10, width: 2 * r, height: 2 * r)),
                       with: .color(lava2.opacity(0.8 * (1 - Double(i) / 10))))
            }
        }

        var g = c
        g.translateBy(x: st.p.x, y: st.p.y)
        g.rotate(by: .radians(st.angle))
        g.scaleBy(x: st.scale, y: st.scale)
        g.opacity = st.alpha
        let r = CGRect(x: -e.size.width / 2, y: -e.size.height / 2, width: e.size.width, height: e.size.height)

        if rising {   // halo and wings behind the card
            let k = (s - e.burnEnd) / (e.riseEnd - e.burnEnd)
            let flap = sin(t * 14) * 0.35
            let wing = e.style == .phoenix ? lava2 : Color.white
            for side in [-1.0, 1.0] {
                var w = g
                w.translateBy(x: side * r.width * 0.42, y: -r.height * 0.1)
                w.rotate(by: .radians(side * (-0.5 + flap)))
                var p = Path()
                p.move(to: .zero)
                p.addQuadCurve(to: CGPoint(x: side * 95, y: -40), control: CGPoint(x: side * 40, y: -70))
                p.addQuadCurve(to: CGPoint(x: side * 70, y: -5), control: CGPoint(x: side * 95, y: -18))
                p.addQuadCurve(to: CGPoint(x: side * 50, y: 18), control: CGPoint(x: side * 70, y: 10))
                p.addQuadCurve(to: .zero, control: CGPoint(x: side * 25, y: 22))
                w.fill(p, with: .color(wing.opacity(0.92)))
                w.stroke(p, with: .color(Color(red: 0.72, green: 0.6, blue: 0.9)), lineWidth: 2)
            }
            let halo = Path(ellipseIn: CGRect(x: -38, y: r.minY - 34, width: 76, height: 18))
            g.stroke(halo, with: .color(Color(red: 1, green: 0.9, blue: 0.45)), lineWidth: 5)
            g.fill(Path(roundedRect: r.insetBy(dx: -14, dy: -14), cornerRadius: 26),
                   with: .color(Color.white.opacity(0.18 + 0.12 * sin(t * 8))))
            for i in 0..<8 {   // sparkles
                let a = Double(i) / 8 * 2 * .pi + t * 1.5
                let d = r.width * 0.62 + 10 * sin(t * 5 + Double(i))
                drawGlyph(g, .sparkle, size: 12 + 6 * rnd(seed, i), at: CGPoint(x: cos(a) * d, y: sin(a) * d * 0.45),
                          color: .white, opacity: 0.5 + 0.5 * sin(t * 6 + Double(i)))
            }
            _ = k
        }

        g.draw(e.card, in: r)
        if st.fire > 0 {   // scorch: the card glows orange and chars as it burns
            g.fill(Path(roundedRect: r, cornerRadius: 14),
                   with: .linearGradient(Gradient(colors: [lava2.opacity(0.75 * st.fire), lava3.opacity(0.55 * st.fire)]),
                                         startPoint: CGPoint(x: 0, y: r.maxY), endPoint: CGPoint(x: 0, y: r.minY)))
            for i in 0..<7 {   // little flames licking up the card
                let fx = r.minX + (Double(i) + 0.5) / 7 * r.width
                let fh = (14 + 16 * rnd(seed, i + 200)) * st.fire * (0.7 + 0.3 * sin(t * 11 + Double(i)))
                var f = Path()
                f.move(to: CGPoint(x: fx - 7, y: r.maxY))
                f.addQuadCurve(to: CGPoint(x: fx, y: r.maxY - fh), control: CGPoint(x: fx - 9, y: r.maxY - fh * 0.4))
                f.addQuadCurve(to: CGPoint(x: fx + 7, y: r.maxY), control: CGPoint(x: fx + 9, y: r.maxY - fh * 0.4))
                g.fill(f, with: .color(lava1.opacity(0.85 * st.fire)))
            }
        }
    }
}

/// Runs the overlay window. One per screen at a time; it disappears when the last effect ends.
@MainActor
final class Pit {
    static let shared = Pit()
    let model = PitModel()
    private var panel: NSPanel?          // made once and reused (hidden windows stay in memory, so don't make new ones)
    private(set) var showing = false
    var window: NSPanel? { showing ? panel : nil }
    private var reaper: Timer?

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Drop a card into the pit. `rect` is where the row is on screen (AppKit coordinates).
    @discardableResult
    func drop(key: String, card: NSImage, from rect: CGRect, resurrect: Bool, style: PitStyle = .current) -> Bool {
        guard style != .off, !reduceMotion, !model.effects.contains(where: { $0.key == key }) else { return false }
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens[0]
        let w = panel ?? makeWindow()
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        let start = CGPoint(x: rect.midX - screen.frame.minX, y: screen.frame.maxY - rect.midY)
        model.effects.append(PitEffect(key: key, card: Image(nsImage: card), size: rect.size, start: start,
                                       born: Date(), style: style, resurrect: resurrect))
        w.orderFrontRegardless()
        showing = true
        if reaper == nil {
            reaper = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { Pit.shared.reap() }
            }
        }
        return true
    }

    private func makeWindow() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)   // above the notch, so cards fall out of it
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: PitScene(model: model))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    func reap() {
        let now = Date()
        model.effects.removeAll { now.timeIntervalSince($0.born) > $0.end }
        if model.effects.isEmpty {
            panel?.orderOut(nil)        // hidden, not destroyed: the next drop reuses it
            showing = false
            reaper?.invalidate(); reaper = nil
        }
    }
}

@MainActor
func pitCard(for job: Job, title: String, model: Model, width: CGFloat, dark: Bool) -> NSImage? {
    let view = Row(model: model, job: job, title: title)
        .frame(width: max(200, width - 28))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Color.black : Color.barBg))
        .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: view)
    r.scale = 1      // it's small and moving fast while it falls: 1x looks the same and uses a quarter of the memory
    return r.nsImage
}

struct PitMenu: View {
    var body: some View {
        Menu("Remove animation") {
            ForEach(PitStyle.allCases, id: \.self) { s in
                Button((PitStyle.current == s ? "✓ " : "") + s.label) { PitStyle.current = s }
            }
        }
    }
}
