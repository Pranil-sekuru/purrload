// Tools for checking the fiery pit without watching the screen:
//   --pit-storyboard out.png   frames from every style, side by side
//   --pit-stress out.log       many effects at once: frame rate, click-through, clean-up, memory
//   --pit-demo [style|all]     plays it live on screen for ~20 seconds
import SwiftUI
import AppKit

@MainActor
private func sampleCard(_ title: String, _ caption: String, dark: Bool = true) -> NSImage {
    let v = VStack(alignment: .leading, spacing: 5) {
        HStack { Text(title).font(.system(size: 12, weight: .medium)); Spacer(); Text("40%").font(.system(size: 11, weight: .semibold)) }
        Line(fraction: 0.4)
        Text(caption).font(.system(size: 10.5)).foregroundStyle(Color.soft)
        HStack(spacing: 14) { Text("Retry").foregroundStyle(Color.lilac); Text("Remove").foregroundStyle(Color.soft) }
            .font(.system(size: 11, weight: .semibold))
    }
    .foregroundStyle(Color.ink)
    .frame(width: 330).padding(14)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Color.black : Color.barBg))
    .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: v)
    r.scale = 1      // same as real cards (pitCard)
    return r.nsImage ?? NSImage()
}

// MARK: storyboard

@MainActor
func pitStoryboard(to path: String) {
    let card = sampleCard("Tears of Steel 4K", "download kept failing")
    let size = CGSize(width: card.size.width, height: card.size.height)
    let born = Date()
    struct Scenario { let label: String; let style: PitStyle; let resurrect: Bool }
    let scenarios = [Scenario(label: "Classic drop · Remove", style: .classic, resurrect: false),
                     Scenario(label: "Kitty swat · Remove", style: .swat, resurrect: false),
                     Scenario(label: "Phoenix · Remove", style: .phoenix, resurrect: false),
                     Scenario(label: "Classic · Retry (resurrected)", style: .classic, resurrect: true),
                     Scenario(label: "Phoenix · Retry (resurrected)", style: .phoenix, resurrect: true)]

    func frame(_ sc: Scenario, at s: Double, _ caption: String) -> some View {
        let m = PitModel()
        m.effects = [PitEffect(key: "k", card: Image(nsImage: card), size: CGSize(width: size.width * 0.62, height: size.height * 0.62),
                               start: CGPoint(x: 240, y: 92), born: born, style: sc.style, resurrect: sc.resurrect)]
        return VStack(spacing: 4) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.62), Color(red: 0.86, green: 0.62, blue: 0.70)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.2)).frame(height: 16)
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black).frame(width: 250, height: 160)
                PitScene(model: m, frozenAt: born.addingTimeInterval(s), floor: 70)
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.3)).frame(width: 260, height: 22)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 4)                                  // the Dock
            }
            .frame(width: 380, height: 420).clipped()
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        }
    }

    func moments(_ sc: Scenario) -> [(Double, String)] {
        let e = PitEffect(key: "", card: Image(nsImage: card), size: .zero, start: .zero, born: born, style: sc.style, resurrect: sc.resurrect)
        var m: [(Double, String)] = [(e.lead * 0.6, sc.style == .swat ? "swat!" : "pop"), (e.lead + e.fall * 0.45, "falling"),
                                     (e.land + 0.12, "splash"), (e.land + 0.4, "sinking")]
        m += sc.resurrect ? [(e.burnEnd + 0.45, "rising"), (e.burnEnd + 0.95, "almost home")] : [(e.burnEnd + 0.5, "embers")]
        return m
    }

    let sheet = VStack(alignment: .leading, spacing: 22) {
        ForEach(scenarios.indices, id: \.self) { i in
            let sc = scenarios[i]
            VStack(alignment: .leading, spacing: 8) {
                Text(sc.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 10) {
                    ForEach(Array(moments(sc).enumerated()), id: \.offset) { _, m in frame(sc, at: m.0, m.1) }
                }
            }
        }
    }
    .padding(22).background(Color(white: 0.2))
    let r = ImageRenderer(content: sheet)
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

// MARK: stress test and live demo (need a running app for windows and animation)

private func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

@MainActor
final class PitToolDelegate: NSObject, NSApplicationDelegate {
    let mode: String, arg: String
    init(mode: String, arg: String) { self.mode = mode; self.arg = arg }

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { mode == "stress" ? await stress(arg) : await demo(arg) }
    }

    func startRect(_ i: Int) -> CGRect {
        let s = NSScreen.main!.frame
        return CGRect(x: s.midX - 180 + CGFloat(i % 5) * 20, y: s.maxY - 180 - CGFloat(i % 4) * 30, width: 360, height: 92)
    }

    func stress(_ out: String) async {
        if out.hasSuffix("-realistic.log") { return await realistic(out) }
        let pit = Pit.shared
        let card = sampleCard("Stress test", "falling, burning, rising")
        var lines = ["fiery pit stress test", ""]
        try? await Task.sleep(for: .seconds(0.5))
        let baseWindows = NSApp.windows.filter(\.isVisible).count
        let mem0 = residentMB()

        func wave(_ label: String) async -> (fps: Double, clickThrough: Bool, maxLive: Int) {
            var clickThrough = true, maxLive = 0
            let f0 = pitFrames, t0 = Date()
            for i in 0..<25 {     // 25 drops, one every 40 ms, every style, half of them resurrecting
                let style: PitStyle = [.classic, .swat, .phoenix][i % 3]
                pit.drop(key: "\(label)-\(i)", card: card, from: startRect(i), resurrect: i % 2 == 0, style: style)
                try? await Task.sleep(for: .milliseconds(40))
                if let w = pit.window { clickThrough = clickThrough && w.ignoresMouseEvents }
                maxLive = max(maxLive, pit.model.effects.count)
            }
            for _ in 0..<15 {     // the busiest stretch, everything on screen
                try? await Task.sleep(for: .milliseconds(100))
                if let w = pit.window { clickThrough = clickThrough && w.ignoresMouseEvents }
                maxLive = max(maxLive, pit.model.effects.count)
            }
            let fps = Double(pitFrames - f0) / Date().timeIntervalSince(t0)
            return (fps, clickThrough, maxLive)
        }

        var mems: [Double] = []
        let a = await wave("a")
        let first = pit.drop(key: "dup", card: card, from: startRect(0), resurrect: false, style: .classic)
        let second = pit.drop(key: "dup", card: card, from: startRect(0), resurrect: false, style: .classic)
        try? await Task.sleep(for: .seconds(4.5))
        let cleaned1 = pit.window == nil && pit.model.effects.isEmpty
        mems.append(residentMB())
        var b = a
        for w in ["b", "c", "d"] {      // first waves warm up caches; a leak keeps growing after that
            b = await wave(w)
            try? await Task.sleep(for: .seconds(5))
            mems.append(residentMB())
        }
        let cleaned2 = pit.window == nil && pit.model.effects.isEmpty
        let windowsAfter = NSApp.windows.filter(\.isVisible).count

        func row(_ label: String, _ ok: Bool, _ detail: String = "") { lines.append("\(ok ? "ok   " : "WRONG") \(label)\(detail.isEmpty ? "" : "  (\(detail))")") }
        row("frame rate with up to \(a.maxLive) cards at once stays smooth", a.fps >= 45, String(format: "%.0f fps", a.fps))
        row("later waves also smooth", b.fps >= 45, String(format: "%.0f fps, %d cards", b.fps, b.maxLive))
        row("overlay never catches clicks", a.clickThrough && b.clickThrough)
        row("the same row can't fall twice at once", first && !second)
        row("overlay window closes after the effects", cleaned1 && cleaned2)
        row("no leftover visible windows", windowsAfter == baseWindows, "\(baseWindows) before, \(windowsAfter) after")
        let growth = mems[mems.count - 1] - mems[mems.count - 2]
        row("memory levels off (wave 3 → wave 4 grows < 8 MB)", growth < 8,
            "start \(Int(mem0)) MB, after each wave: " + mems.map { "\(Int($0))" }.joined(separator: " → ") + " MB")
        let wrong = lines.filter { $0.hasPrefix("WRONG") }.count
        lines += ["", "TOTAL \(7 - wrong)/7"]
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Normal use: one row at a time. How much does the app grow?
    func realistic(_ out: String) async {
        try? await Task.sleep(for: .seconds(0.5))
        let mem0 = residentMB()
        var mems: [Int] = []
        let n = Int(ProcessInfo.processInfo.environment["PIT_N"] ?? "12") ?? 12
        for i in 0..<n {
            let card = sampleCard("Download \(i + 1)", "removed")
            Pit.shared.drop(key: "r\(i)", card: card, from: startRect(i), resurrect: i % 2 == 1, style: [.classic, .swat, .phoenix][i % 3])
            try? await Task.sleep(for: .seconds(4.6))
            mems.append(Int(residentMB()))
        }
        let line = "one at a time: start \(Int(mem0)) MB, after each: " + mems.map(String.init).joined(separator: " → ") + " MB"
        try? line.write(toFile: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func demo(_ which: String) async {
        let styles: [PitStyle] = which == "all" ? [.classic, .swat, .phoenix] : [PitStyle(rawValue: which) ?? .classic]
        try? await Task.sleep(for: .seconds(0.5))
        var round = 0
        for _ in 0..<2 {
            for style in styles {
                for resurrect in [false, true] {
                    let card = sampleCard("\(style.label)", resurrect ? "Retry: falls in, burns, and comes back" : "Remove: falls in and burns")
                    let s = NSScreen.main!.frame
                    Pit.shared.drop(key: "demo-\(round)", card: card,
                                    from: CGRect(x: s.midX - 180, y: s.maxY - 190, width: 360, height: 100), resurrect: resurrect, style: style)
                    round += 1
                    try? await Task.sleep(for: .seconds(resurrect ? 4.2 : 3.2))
                }
            }
        }
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }
}
