// The kitty that sits on top of the Purrload bar. Drawn with Canvas, animated from timestamps
// (no @State: the Command Line Tools lack SwiftUI's macro plugin).
import SwiftUI

enum Eyes { case open, closed, happy, half }

struct Pose {
    var lift: CGFloat = 0          // jump height
    var squash: CGFloat = 1        // body height scale
    var eyes: Eyes = .open
    var yawn: CGFloat = 0          // 0...1 mouth open
    var smile = false
    var wave: CGFloat = 0          // 0...1 paw raised
    var waveAngle: CGFloat = 0
    var tilt: CGFloat = 0          // head sideways offset
    var headDrop: CGFloat = 0
    var earPerk: CGFloat = 0
    var tailSpeed: Double = 1.4
    var tailAmp: CGFloat = 1
    var hearts: Double? = nil      // 0...1 progress
    var sleeping = false
}

func pose(at now: Date, expanded: Bool, toggledAt: Date, pettedAt: Date, active: Bool) -> Pose {
    var p = Pose()
    let t = now.timeIntervalSinceReferenceDate
    let tt = now.timeIntervalSince(toggledAt)
    let tp = now.timeIntervalSince(pettedAt)
    p.tailSpeed = active ? 2.6 : 1.4

    if expanded && tt < 0.75 {                       // crouch, then jump
        let k = tt / 0.75
        if k < 0.2 { p.squash = 1 - 0.18 * CGFloat(sin(k / 0.2 * .pi)) }
        else { p.lift = 16 * CGFloat(sin((k - 0.2) / 0.8 * .pi)); p.earPerk = 3 }
    } else if expanded && tt < 2.3 {                 // happy wave
        p.eyes = .happy; p.smile = true
        p.wave = CGFloat(min(1, (tt - 0.75) * 6, (2.3 - tt) * 6))
        p.waveAngle = CGFloat(sin(tt * 15)) * 0.45
    } else if !expanded && tt < 1.9 {                // yawn, stretch, settle
        let y = (tt - 0.1) / 1.1
        if y > 0 && y < 1 { p.yawn = CGFloat(sin(y * .pi)); p.eyes = .closed; p.headDrop = -2 * p.yawn }
        if tt > 1.2 { p.squash = 1 - 0.08 * CGFloat(sin((tt - 1.2) / 0.7 * .pi)); p.eyes = .half }
    } else if !expanded && !active {                 // nap
        p.sleeping = true; p.eyes = .closed; p.headDrop = 2.5; p.squash = 0.94
        p.tailAmp = 0.25; p.tailSpeed = 0.6
    }

    if tp < 1.6 {                                    // petted
        p.hearts = tp / 1.6; p.eyes = .happy; p.smile = true; p.sleeping = false; p.headDrop = 0
        p.lift = max(p.lift, 4 * CGFloat(abs(sin(tp * 7))) * CGFloat(1 - tp / 1.6))
    }
    if p.eyes == .open && t.truncatingRemainder(dividingBy: 4.3) < 0.14 { p.eyes = .closed }   // blink
    if active && !p.sleeping { p.earPerk += CGFloat(max(0, sin(t * 0.9) - 0.9) * 20) }         // ear twitch
    return p
}

private let fur = Color(red: 1.0, green: 0.965, blue: 0.925)
private let line = Color(red: 0.29, green: 0.23, blue: 0.37)
private let pink = Color(red: 0.96, green: 0.64, blue: 0.71)

func drawKitty(_ c: GraphicsContext, size: CGSize, pose p: Pose, time t: Double) {
    let cx = size.width / 2, ground = size.height - 4, L = p.lift
    let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    func blob(_ path: Path, _ color: Color = fur) { c.fill(path, with: .color(color)); c.stroke(path, with: .color(line), style: stroke) }

    // tail
    let sway = CGFloat(sin(t * p.tailSpeed)) * 6 * p.tailAmp
    var tail = Path()
    tail.move(to: CGPoint(x: cx + 11, y: ground - 4 - L))
    tail.addCurve(to: CGPoint(x: cx + 23 + sway * 0.6, y: ground - 24 - L + abs(sway) * 0.3),
                  control1: CGPoint(x: cx + 27, y: ground - 3 - L),
                  control2: CGPoint(x: cx + 20 + sway, y: ground - 14 - L))
    c.stroke(tail, with: .color(line), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
    c.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))

    // body
    let bh = 22 * p.squash
    blob(Path(ellipseIn: CGRect(x: cx - 14, y: ground - bh - L, width: 28, height: bh)))

    // front paws
    if p.wave < 0.05 { blob(Path(ellipseIn: CGRect(x: cx - 10, y: ground - 4.5 - L, width: 8, height: 5))) }
    blob(Path(ellipseIn: CGRect(x: cx + 2, y: ground - 4.5 - L, width: 8, height: 5)))

    // head
    let hx = cx + p.tilt, hy = ground - bh - 7 - L + p.headDrop, r: CGFloat = 12
    drawHead(c, hx: hx, hy: hy, r: r, pose: p)

    // waving paw (left side, away from the tail)
    if p.wave >= 0.05 {
        var pc = c
        let px = cx - 12, py = ground - bh * 0.5 - L     // shoulder pivot; paw held up beside the cheek
        pc.translateBy(x: px, y: py)
        pc.rotate(by: .radians(Double(-0.12 * p.wave + 0.6 * p.waveAngle * p.wave)))
        let arm = Path(roundedRect: CGRect(x: -3.5, y: -4 - 11 * p.wave, width: 6.5, height: 6 + 11 * p.wave), cornerRadius: 3.2)
        pc.fill(arm, with: .color(fur)); pc.stroke(arm, with: .color(line), style: stroke)
    }

    drawExtras(c, hx: hx, hy: hy, pose: p, time: t)
}

private let kittyStroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
private func kittyBlob(_ c: GraphicsContext, _ path: Path, _ color: Color = fur) {
    c.fill(path, with: .color(color)); c.stroke(path, with: .color(line), style: kittyStroke)
}

/// Ears, head and face.
func drawHead(_ c: GraphicsContext, hx: CGFloat, hy: CGFloat, r: CGFloat, pose p: Pose) {
    func blob(_ path: Path, _ color: Color = fur) { kittyBlob(c, path, color) }
    for side in [-1.0, 1.0] as [CGFloat] {          // ears behind the head
        var ear = Path()
        ear.move(to: CGPoint(x: hx + side * 11, y: hy - 3))
        ear.addLine(to: CGPoint(x: hx + side * 9, y: hy - 18 - p.earPerk))
        ear.addLine(to: CGPoint(x: hx + side * 1.5, y: hy - 10))
        ear.closeSubpath()
        blob(ear)
        var inner = Path()
        inner.move(to: CGPoint(x: hx + side * 9, y: hy - 6))
        inner.addLine(to: CGPoint(x: hx + side * 8.6, y: hy - 14 - p.earPerk))
        inner.addLine(to: CGPoint(x: hx + side * 4, y: hy - 9))
        inner.closeSubpath()
        c.fill(inner, with: .color(pink))
    }
    blob(Path(ellipseIn: CGRect(x: hx - r, y: hy - r * 0.92, width: r * 2, height: r * 1.84)))

    // blush
    for side in [-1.0, 1.0] as [CGFloat] {
        c.fill(Path(ellipseIn: CGRect(x: hx + side * 7.5 - 2.5, y: hy + 3, width: 5, height: 3)), with: .color(pink.opacity(0.55)))
    }

    // eyes
    for side in [-1.0, 1.0] as [CGFloat] {
        let ex = hx + side * 4.6, ey = hy - 0.5
        var e = Path()
        switch p.eyes {
        case .open:
            c.fill(Path(ellipseIn: CGRect(x: ex - 1.7, y: ey - 2.4, width: 3.4, height: 4.6)), with: .color(line))
            c.fill(Path(ellipseIn: CGRect(x: ex - 0.4, y: ey - 1.8, width: 1.3, height: 1.3)), with: .color(.white))
            continue
        case .half:
            c.fill(Path(ellipseIn: CGRect(x: ex - 1.8, y: ey - 0.6, width: 3.6, height: 2)), with: .color(line))
            continue
        case .closed:
            e.move(to: CGPoint(x: ex - 2.3, y: ey)); e.addQuadCurve(to: CGPoint(x: ex + 2.3, y: ey), control: CGPoint(x: ex, y: ey + 2.2))
        case .happy:
            e.move(to: CGPoint(x: ex - 2.3, y: ey + 1)); e.addQuadCurve(to: CGPoint(x: ex + 2.3, y: ey + 1), control: CGPoint(x: ex, y: ey - 2.4))
        }
        c.stroke(e, with: .color(line), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    // nose + mouth
    var nose = Path()
    nose.move(to: CGPoint(x: hx - 1.4, y: hy + 3)); nose.addLine(to: CGPoint(x: hx + 1.4, y: hy + 3))
    nose.addLine(to: CGPoint(x: hx, y: hy + 4.4)); nose.closeSubpath()
    c.fill(nose, with: .color(pink))
    if p.yawn > 0.05 {
        let w = 3 + 2.5 * p.yawn, h = 2 + 5 * p.yawn
        let m = Path(ellipseIn: CGRect(x: hx - w / 2, y: hy + 5, width: w, height: h))
        c.fill(m, with: .color(Color(red: 0.62, green: 0.25, blue: 0.36))); c.stroke(m, with: .color(line), lineWidth: 1)
    } else {
        var m = Path()
        let dip: CGFloat = p.smile ? 2 : 1.2
        m.move(to: CGPoint(x: hx - 2.6, y: hy + 5)); m.addQuadCurve(to: CGPoint(x: hx, y: hy + 5), control: CGPoint(x: hx - 1.3, y: hy + 5 + dip))
        m.addQuadCurve(to: CGPoint(x: hx + 2.6, y: hy + 5), control: CGPoint(x: hx + 1.3, y: hy + 5 + dip))
        c.stroke(m, with: .color(line), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

}

/// Hearts and sleepy z's above the head.
func drawExtras(_ c: GraphicsContext, hx: CGFloat, hy: CGFloat, pose p: Pose, time t: Double, zColor: Color = line) {
    // hearts
    if let h = p.hearts {
        for (i, dx) in [(0, 13.0), (1, -12.0), (2, 4.0)] {
            let k = h - Double(i) * 0.18
            guard k > 0, k < 1 else { continue }
            let x = hx + CGFloat(dx) + CGFloat(sin(k * 9)) * 2, y = hy - 14 - CGFloat(k) * 26, s: CGFloat = 4.5
            var heart = Path()
            heart.move(to: CGPoint(x: x, y: y + s * 0.9))
            heart.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x - s * 1.4, y: y), control2: CGPoint(x: x - s * 0.6, y: y - s * 0.9))
            heart.addCurve(to: CGPoint(x: x, y: y + s * 0.9), control1: CGPoint(x: x + s * 0.6, y: y - s * 0.9), control2: CGPoint(x: x + s * 1.4, y: y))
            c.fill(heart, with: .color(Color(red: 0.94, green: 0.38, blue: 0.48).opacity(1 - k)))
        }
    }

    // zzz
    if p.sleeping {
        for i in 0..<3 {
            let k = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let txt = Text("z").font(.system(size: 7 + 4 * k, weight: .bold, design: .rounded)).foregroundColor(zColor.opacity(0.75 * (1 - k)))
            c.draw(txt, at: CGPoint(x: hx + 12 + CGFloat(k) * 10, y: hy - 12 - CGFloat(k) * 20))
        }
    }
}

nonisolated(unsafe) var kittyFrames = 0   // frames drawn, for the stress test's fps figure

struct KittyView: View {
    @ObservedObject var model: Model
    var frozenAt: Date? = nil      // snapshots render a single moment

    var body: some View {
        Group {
            if let at = frozenAt { canvas(at) }
            else {
                // Full display rate while moving; a slow tick while napping (body re-evaluates each status update)
                TimelineView(.animation(minimumInterval: napping ? 1 / 12 : nil)) { ctx in canvas(ctx.date) }
            }
        }
        .frame(width: 76, height: 72)
        .contentShape(Rectangle())
        .onTapGesture { model.pet() }
        .help("Pet the kitty")
    }

    var napping: Bool {
        let now = Date()
        return !model.expanded && !model.isActive && now.timeIntervalSince(model.toggledAt) > 2.5
            && now.timeIntervalSince(model.pettedAt) > 1.6
    }

    func canvas(_ date: Date) -> some View {
        if frozenAt == nil { kittyFrames += 1 }
        let p = pose(at: date, expanded: model.expanded, toggledAt: model.toggledAt,
                     pettedAt: model.pettedAt, active: model.isActive)
        return Canvas { c, size in drawKitty(c, size: size, pose: p, time: date.timeIntervalSinceReferenceDate) }
    }
}
