// Purrload: a tiny download bar (or notch) with a cat on top.
// Reads the engine's status.json once a second; never downloads anything itself.
import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - Data from the engine

struct Job: Decodable, Identifiable {
    let id: String
    let name: String
    let title: String
    let state: String
    let done: Double
    let total: Double
    let speed: Double
    let eta: Double?
    let folder: String
    var message: String? = nil
    var files: [TorrentFile]? = nil     // torrents waiting for the user to choose
    var canRetry: Bool? = nil
    var path: String? = nil             // finished: what "Show in Finder" selects

    var fraction: Double { total > 0 ? min(done / total, 1) : 0 }
    var active: Bool { ["downloading", "takeover", "failed", "starting", "metadata"].contains(state) }
}

struct TorrentFile: Decodable, Identifiable {
    let index: Int
    let path: String
    let size: Double
    let kind: String          // media / subtitle / other
    let flags: [String]
    let blocked: Bool         // flagged by the safety check: can't be picked
    let preselect: Bool

    var id: Int { index }
    var fileName: String { (path as NSString).lastPathComponent }
}

struct Status: Decodable {
    let updated: Double
    let speed: Double
    let paused: Bool
    var online: Bool? = nil
    var events: [EngineEvent]? = nil
    let jobs: [Job]
}

nonisolated(unsafe) var useDemoData = false   // --demo: made-up downloads for screenshots

let demoStatus: Status = {
    let gb = 1_073_741_824.0, now = Date().timeIntervalSince1970, dir = NSTemporaryDirectory()
    func job(_ title: String, _ done: Double, _ total: Double, _ speed: Double, _ state: String = "takeover") -> Job {
        // (a var so callers can add files/messages)
        Job(id: title, name: title, title: "Blender Open Movies \(title)", state: state, done: done * gb, total: total * gb,
            speed: speed * 1_048_576, eta: speed > 0 ? (total - done) * gb / (speed * 1_048_576) : nil, folder: dir)
    }
    let mb = 1_048_576.0
    func f(_ i: Int, _ path: String, _ size: Double, _ kind: String, _ flags: [String] = [], blocked: Bool = false) -> TorrentFile {
        TorrentFile(index: i, path: path, size: size, kind: kind, flags: flags, blocked: blocked, preselect: kind != "other" && !blocked)
    }
    var choosing = job("Cosmos Laundromat", 0, 0, 0, "choosing")
    choosing.files = [f(1, "Cosmos.Laundromat.2015.1080p.mkv", 1210 * mb, "media"), f(2, "Cosmos.Laundromat.en.srt", 0.05 * mb, "subtitle"),
                      f(3, "Cosmos.Laundromat.de.srt", 0.05 * mb, "subtitle"), f(4, "poster.jpg", 0.4 * mb, "other"),
                      f(5, "Extras/Codec Setup.zip", 2 * mb, "other", ["archive: can hide anything"]),
                      f(6, "Cosmos Laundromat Player.exe", 3 * mb, "other", [".exe file: not a media file"], blocked: true)]
    var failed = job("Spring", 0.2, 0.3, 0, "corrupt")
    failed.message = "download kept failing; drop the link again to retry"; failed.canRetry = true
    return Status(updated: now, speed: 4.6 * 1_048_576, paused: false, jobs: [
        job("Sintel 4K", 1.6, 2.5, 1.9), job("Tears of Steel 4K", 0.9, 2.2, 1.4),
        choosing, job("Big Buck Bunny 4K", 1.4, 1.4, 0, "verified"), failed,
    ])
}()

@MainActor
final class Model: ObservableObject {
    @Published var status: Status?
    @Published var expanded = false
    @Published var toggledAt = Date.distantPast   // drives the kitty's open/close animations
    @Published var pettedAt = Date.distantPast
    @Published var flashTitle: String?           // "S02E10 ready", shown briefly in notch mode
    var flashAt = Date.distantPast
    var lastStates: [String: String] = [:]
    // drop to download
    @Published var offer: String?                // a copied download link, offered for ~10s
    var offerAt = Date.distantPast
    @Published var dropTarget = false            // a link is being dragged over
    var clipboardChange = NSPasteboard.general.changeCount   // ignore whatever was copied before launch
    var watchClipboard: Bool {
        get { UserDefaults.standard.object(forKey: "watchClipboard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "watchClipboard"); objectWillChange.send() }
    }
    @Published var picks: [String: Set<Int>] = [:]   // torrent file choices, per job
    var rowFrames: [String: CGRect] = [:]          // where each row is in the window (for the fiery pit)
    var toScreen: ((CGRect) -> CGRect)?            // window -> screen coordinates, set by the app delegate
    var darkRows = false                           // notch rows are drawn on black
    var swatAt = Date.distantPast
    // kitty moods
    var caughtAt = Date.distantPast, celebrateAt = Date.distantPast, alertAt = Date.distantPast
    var slowSince: Date?
    var lastActive = 0
    var switchMode: (() -> Void)?
    let base: URL = {
        if let custom = ProcessInfo.processInfo.environment["PURRLOAD_HOME"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Purrload")
    }()
    private var timer: Timer?

    init() {
        if useDemoData { status = demoStatus; return }
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("status.json")),
              let s = try? JSONDecoder().decode(Status.self, from: data) else { return }
        for j in s.jobs {
            let old = lastStates[j.id]
            if let old, old != "verified", j.state == "verified" { announce("\(j.name) ready") }   // passed its check
            if old != "danger", j.state == "danger" { alertAt = Date(); announce("⚠ \(j.name) flagged") }
            if old != "choosing", j.state == "choosing" { announce("Choose files: \(j.name.prefix(16))") }
            lastStates[j.id] = j.state
        }
        status = s
        if !useDemoData { Notifier.shared.handle(s.events ?? []) }
        let now = Date()
        let active = activeJobs.count
        if lastActive > 0 && active == 0 && jobs.contains(where: { $0.state == "verified" }) { celebrateAt = now }
        lastActive = active
        slowSince = isActive && s.speed < 20_000 ? (slowSince ?? now) : nil
        if flashTitle != nil && now.timeIntervalSince(flashAt) > 4 {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { flashTitle = nil }
        }
    }

    func tick() {
        load()
        checkClipboard()
        if offer != nil && Date().timeIntervalSince(offerAt) > 10 && !expanded { dismissOffer() }
    }

    /// The strip widens while it has something to say.
    var wide: Bool { flashTitle != nil || offer != nil || dropTarget }

    var kittyContext: KittyContext {
        let now = Date()
        return KittyContext(expanded: expanded, toggledAt: toggledAt, pettedAt: pettedAt, active: isActive,
                            fast: isActive && (status?.speed ?? 0) >= 3 * 1_048_576,
                            worried: isActive && (status?.online == false || now.timeIntervalSince(slowSince ?? now) > 20),
                            dropTarget: dropTarget, caughtAt: caughtAt, celebrateAt: celebrateAt, alertAt: alertAt,
                            swatAt: swatAt)
    }

    func announce(_ title: String) {
        flashAt = Date()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { flashTitle = title }
    }

    // The engine stops writing if it isn't running; don't show frozen numbers as live.
    var guardRunning: Bool {
        guard let s = status else { return false }
        return Date().timeIntervalSince1970 - s.updated < 30
    }

    var jobs: [Job] { status?.jobs ?? [] }
    var isActive: Bool { guardRunning && !activeJobs.isEmpty && status?.paused != true }

    func toggle() { expanded.toggle(); toggledAt = Date() }
    func pet() { pettedAt = Date() }

    // Words every title starts with (the show's name), shown once instead of on every row.
    var series: String {
        guard jobs.count > 1 else { return "" }
        var common = jobs[0].title.split(separator: " ")
        for j in jobs.dropFirst() {
            let w = j.title.split(separator: " ")
            common = Array(zip(common, w).prefix { $0 == $1 }.map(\.0))
        }
        return common.joined(separator: " ")
    }
    func rowTitle(_ j: Job) -> String {
        let s = series
        guard !s.isEmpty, j.title.count > s.count else { return j.title }
        return String(j.title.dropFirst(s.count)).trimmingCharacters(in: .whitespaces)
    }
    var activeJobs: [Job] { jobs.filter(\.active) }
    var overall: Double {
        let t = jobs.reduce(0) { $0 + $1.total }
        return t > 0 ? jobs.reduce(0) { $0 + $1.done } / t : 0
    }

    func togglePause() {
        let p = base.appendingPathComponent("PAUSE").path
        if FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.removeItem(atPath: p)
        } else {
            FileManager.default.createFile(atPath: p, contents: nil)
        }
        status = nil
        load()
    }

    // MARK: torrent file picker

    func selection(for j: Job) -> Set<Int> {
        picks[j.id] ?? Set((j.files ?? []).filter(\.preselect).map(\.index))
    }
    func togglePick(_ f: TorrentFile, in j: Job) {
        guard !f.blocked else { return }
        var s = selection(for: j)
        if s.contains(f.index) { s.remove(f.index) } else { s.insert(f.index) }
        picks[j.id] = s
    }
    func pick(_ j: Job, _ filter: (TorrentFile) -> Bool) {
        picks[j.id] = Set((j.files ?? []).filter { !$0.blocked && filter($0) }.map(\.index))
    }
    func pickedBytes(_ j: Job) -> Double {
        let s = selection(for: j)
        return (j.files ?? []).filter { s.contains($0.index) }.reduce(0) { $0 + $1.size }
    }
    func startTorrent(_ j: Job) {
        let s = selection(for: j).sorted()
        guard !s.isEmpty, send(["select": j.id, "files": s]) else { return }
        caughtAt = Date()
        announce("Downloading \(s.count) file\(s.count == 1 ? "" : "s")")
    }

    // MARK: row actions

    func retry(_ j: Job) {
        guard send(["retry": j.id]) else { return }
        throwInPit(j, resurrect: true)
    }
    func remove(_ j: Job) {
        _ = send(["remove": j.id]); picks[j.id] = nil
        throwInPit(j, resurrect: false)
    }

    /// The row falls into the fiery pit (and, for Retry, rises again).
    func throwInPit(_ j: Job, resurrect: Bool) {
        let style = PitStyle.current
        guard let frame = rowFrames[j.id], let toScreen,
              let card = pitCard(for: j, title: rowTitle(j), model: self, width: frame.width, dark: darkRows) else { return }
        let rect = toScreen(frame.insetBy(dx: -14, dy: -14))
        if Pit.shared.drop(key: j.id, card: card, from: rect, resurrect: resurrect, style: style) && style == .swat {
            swatAt = Date()
        }
    }
    func reveal(_ j: Job) {
        if let p = j.path, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: j.folder))
        }
    }

    func openFolder() {
        let folder = jobs.first?.folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
    }
}

// MARK: - Palette (soft Espeon lilac, light + dark)

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
    static let barBg   = dyn(0xF4EDFB, 0x261E31)
    static let ink     = dyn(0x3A2C4E, 0xEDE3F7)
    static let soft    = dyn(0x8A7AA0, 0xA898BE)
    static let track   = dyn(0xE3D6F1, 0x3A2F48)
    static let lilac   = dyn(0xB084D9, 0xC29BE6)
    static let gem     = dyn(0xE0475E, 0xF0607A)
    static let mint    = dyn(0x3FA97C, 0x5CC99A)
}

// MARK: - Formatting

func gb(_ b: Double) -> String {
    if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
    if b >= 1_048_576 { return String(format: "%.0f MB", b / 1_048_576) }
    return String(format: "%.0f KB", max(1, b / 1024))
}
func mbs(_ b: Double) -> String { String(format: "%.1f MB/s", b / 1_048_576) }
func left(_ s: Double?) -> String {
    guard let s, s.isFinite, s > 0 else { return "—" }
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m left" : m >= 1 ? "\(m) min left" : "<1 min left"
}

// MARK: - Views

struct Gem: View {
    let active: Bool
    var body: some View {
        // Time-driven pulse (no @State: the Command Line Tools lack SwiftUI's macro plugin)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { ctx in
            let p = active ? (sin(ctx.date.timeIntervalSinceReferenceDate * 3.4) + 1) / 2 : 0
            Circle()
                .fill(active ? Color.gem : Color.soft)
                .frame(width: 8, height: 8)
                .scaleEffect(1 + 0.3 * p)
                .opacity(1 - 0.4 * p)
        }
        .frame(width: 11, height: 11)
    }
}

struct Line: View {
    let fraction: Double
    var height: CGFloat = 4
    var color: Color = .lilac
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule().fill(color).frame(width: max(4, g.size.width * fraction))
                    .animation(.easeOut(duration: 0.8), value: fraction)
            }
        }
        .frame(height: height)
    }
}

struct Row: View {
    @ObservedObject var model: Model
    let job: Job
    let title: String
    var live = false             // on screen (not a measuring/snapshot copy): report where it is
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(Int(job.fraction * 100))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(job.state == "verified" ? Color.mint : Color.soft)
            }
            Line(fraction: job.fraction, color: lineColor)
            Text(caption).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color.soft)
            if job.state == "choosing" { FilePicker(model: model, job: job).padding(.top, 3) }
            else { RowActions(model: model, job: job) }
        }
        .background {
            if live {
                GeometryReader { g in
                    Color.clear
                        .onAppear { model.rowFrames[job.id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in model.rowFrames[job.id] = f }
                }
            }
        }
    }

    var lineColor: Color {
        switch job.state {
        case "verified": return .mint
        case "corrupt", "expired", "danger": return .gem
        default: return .lilac
        }
    }

    var caption: String {
        switch job.state {
        case "verified": return "Ready · \(gb(job.total)) · checked ✓"
        case "corrupt":  return job.message ?? "Failed the check, needs re-downloading"
        case "expired":  return "Link expired, get a fresh one from the site"
        case "starting": return "Getting file info…"
        case "metadata": return "Asking peers for the file list…"
        case "skipped":  return job.message ?? "Skipped"
        case "choosing": return "\(job.files?.count ?? 0) files · pick what to download"
        case "danger":   return "⚠ " + (job.message ?? "Flagged by the safety check: don't open it")
        default:
            return "\(gb(job.done)) of \(gb(job.total)) · \(mbs(job.speed)) · \(left(job.eta))"
        }
    }
}

struct BarView: View {
    @ObservedObject var model: Model
    var kittyAt: Date? = nil
    var measuring: Bool? = nil       // off-screen copies: true = laid out open, false = closed (sizes the window + click areas)
    var open: Bool { measuring ?? model.expanded }

    var body: some View {
        VStack(alignment: .trailing, spacing: -5) {
            KittyView(model: model, frozenAt: measuring != nil ? Date() : kittyAt).padding(.trailing, 30).zIndex(1)
            bar.shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .padding(.horizontal, AppDelegate.margin).padding(.bottom, AppDelegate.margin)
        // The window is always as tall as the open bar; the bar sits at its bottom and animates inside it.
        .frame(maxWidth: measuring != nil ? nil : .infinity, maxHeight: measuring != nil ? nil : .infinity, alignment: .bottom)
    }

    var headline: String {
        if model.dropTarget { return "Drop to download ↓" }
        if let f = model.flashTitle { return f }
        if model.offer != nil && !open { return "Copied a download link · click" }
        if !model.guardRunning { return "Engine isn't running" }
        if model.status?.paused == true { return "Paused" }
        let n = model.activeJobs.count
        if n == 0 { return model.jobs.isEmpty ? "All quiet ✦" : "All done ✦" }
        return "\(n) downloading · \(mbs(model.status?.speed ?? 0))"
    }

    var bar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Gem(active: model.isActive)
                Text(headline).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer(minLength: 10)
                if !model.jobs.isEmpty {
                    Text("\(Int(model.overall * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.lilac)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Color.soft)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)

            Line(fraction: model.overall).padding(.horizontal, 14).padding(.bottom, open ? 12 : 11)

            if open {
                VStack(alignment: .leading, spacing: 13) {
                    OfferRow(model: model)
                    if !model.series.isEmpty {
                        Text(model.series).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.soft)
                            .textCase(.uppercase).tracking(0.6).padding(.bottom, -5)
                    }
                    ForEach(model.jobs) { Row(model: model, job: $0, title: model.rowTitle($0), live: measuring == nil && kittyAt == nil) }
                }
                .padding(.horizontal, 14)

                HStack(spacing: 16) {
                    Button(model.status?.paused == true ? "Resume" : "Pause") { model.togglePause() }
                    Button("Open folder") { model.openFolder() }
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.lilac)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            }
        }
        .transition(.opacity)
        .frame(width: 340)
        .background(Color.barBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { model.toggle() } }
        .modifier(LinkDropTarget(model: model, enabled: measuring == nil && kittyAt == nil))
        .contextMenu {
            Button(model.status?.paused == true ? "Resume downloads" : "Pause downloads") { model.togglePause() }
            Button("Open folder") { model.openFolder() }
            Button(model.watchClipboard ? "✓ Offer copied download links" : "Offer copied download links") {
                model.watchClipboard.toggle()
            }
            PitMenu()
            if NotchMetrics.find() != nil { Button("Move to notch") { model.switchMode?() } }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Floating panel

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Notch mode sits over the menu bar; don't let AppKit push the window down into the visible area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: Panel?
    var host: NSHostingView<AnyView>!
    var measureOpen: NSHostingView<AnyView>!      // off-screen copies: size the window and the click areas
    var measureClosed: NSHostingView<AnyView>!
    var openFit = CGSize.zero, closedFit = CGSize.zero
    static let margin: CGFloat = 14               // corner mode: transparent room for the bar's shadow
    static let kitty = CGSize(width: 76, height: 72)
    var mode = "corner"
    var notch: NotchMetrics?
    var notchScreen: NSScreen?
    var bottom: CGFloat = 0                       // corner mode: the bottom edge stays put
    let model = Model()
    var frameEvents: [(t: Double, f: NSRect)] = []
    var monitors: [Any] = []
    var watch: Any?
    var forcedMode: String?
    var hoverSince: Double?                       // notch mode: hover to open, move away to close
    var awaySince: Double?
    static let openDelay = 0.12, closeDelay = 0.35

    func applicationDidFinishLaunching(_ note: Notification) {
        if !CommandLine.arguments.contains("--stress") { Notifier.shared.start(logTo: model.base) }
        if let i = CommandLine.arguments.firstIndex(of: "--mode"), i + 1 < CommandLine.arguments.count {
            forcedMode = CommandLine.arguments[i + 1]
        }
        model.switchMode = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.mode == "notch" ? "corner" : "notch", forKey: "mode")
            self.build()
        }
        build()

        watch = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resizeToFit() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.build() }     // lid closed / monitor plugged in
        }

        // Clicks on the transparent part of the window go to whatever is behind it.
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moved) { [weak self] e in
            MainActor.assumeIsolated { self?.updateMouse() }
            return e
        } as Any)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in   // shape moving under a still mouse
            MainActor.assumeIsolated { self?.updateMouse() }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--stress"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { await self.stress(out) }
        }
    }

    /// (Re)create the window for the current mode: notch if wanted and available, otherwise the corner bar.
    func build() {
        let wanted = forcedMode ?? UserDefaults.standard.string(forKey: "mode") ?? "notch"
        let found = NotchMetrics.find()
        mode = wanted == "notch" && found != nil ? "notch" : "corner"
        panel?.orderOut(nil)

        let p: Panel
        if mode == "notch", let (screen, m) = found {
            notch = m; notchScreen = screen
            host = NSHostingView(rootView: AnyView(NotchView(model: model, metrics: m)))
            measureOpen = NSHostingView(rootView: AnyView(NotchView(model: model, metrics: m, measuring: true)))
            measureClosed = NSHostingView(rootView: AnyView(NotchView(model: model, metrics: m, measuring: false)))
            for v in [host, measureOpen, measureClosed] { v?.appearance = NSAppearance(named: .darkAqua) }   // light text on black
            refreshSizes()
            p = makePanel(size: notchWindowSize())
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // above the menu bar
            p.isMovableByWindowBackground = false
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - p.frame.width / 2, y: screen.frame.maxY - p.frame.height))
        } else {
            notch = nil; notchScreen = nil
            host = NSHostingView(rootView: AnyView(BarView(model: model)))
            measureOpen = NSHostingView(rootView: AnyView(BarView(model: model, measuring: true)))
            measureClosed = NSHostingView(rootView: AnyView(BarView(model: model, measuring: false)))
            refreshSizes()
            p = makePanel(size: openFit)
            p.level = .floating
            p.isMovableByWindowBackground = true
            if let screen = NSScreen.main?.visibleFrame {   // bottom-right, above the Dock
                p.setFrameOrigin(NSPoint(x: screen.maxX - 340 - 20 - Self.margin, y: screen.minY + 20 - Self.margin))
            }
        }
        host.sizingOptions = []                  // the window never follows SwiftUI's size; we set it
        p.contentView = host
        model.darkRows = mode == "notch"
        model.toScreen = { [weak p] r in
            guard let p else { return r }
            return CGRect(x: p.frame.minX + r.minX, y: p.frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        p.orderFrontRegardless()
        panel = p
        bottom = p.frame.minY

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameEvents.append((CACurrentMediaTime(), p.frame))
                if self.mode == "corner", NSEvent.pressedMouseButtons != 0 { self.bottom = p.frame.minY }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameEvents.append((CACurrentMediaTime(), p.frame)) }
        }
    }

    func makePanel(size: CGSize) -> Panel {
        let p = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false   // the window-server shadow lags behind the animated kitty; SwiftUI draws one instead
        p.hidesOnDeactivate = false
        return p
    }

    func refreshSizes() {
        openFit = measureOpen.fittingSize
        closedFit = measureClosed.fittingSize
    }

    /// Wide enough for the widest the strip ever gets (open, or widened to show a message), so its ends are never cut off.
    func notchWindowSize() -> CGSize {
        let widest = max(NotchMetrics.openWidth, notch?.closedWidth(flashing: true) ?? 0)
        return CGSize(width: widest + 40, height: openFit.height + 8)
    }

    /// The window only resizes when the open layout's height changes (downloads added/removed), never on open/close.
    func resizeToFit() {
        guard let p = panel else { return }
        refreshSizes()
        let f = p.frame
        if mode == "notch", let screen = notchScreen {
            let size = notchWindowSize()
            guard abs(size.height - f.height) > 0.5 || abs(size.width - f.width) > 0.5 else { return }
            p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,   // stays centred on the notch
                              width: size.width, height: size.height), display: true)
        } else {
            guard abs(openFit.height - f.height) > 0.5 || abs(openFit.width - f.width) > 0.5 else { return }
            p.setFrame(NSRect(x: f.minX, y: bottom, width: openFit.width, height: openFit.height), display: true)
        }
    }

    /// The solid parts of the window (shape/bar and kitty), in window coordinates with the origin bottom-left.
    func solidRects() -> [CGRect] {
        guard let p = panel else { return [] }
        let w = p.frame.width, h = p.frame.height
        let fit = model.expanded ? openFit : closedFit
        if let m = notch {
            let sw = m.width(open: model.expanded, flashing: model.wide)
            let shape = CGRect(x: (w - sw) / 2, y: h - fit.height, width: sw, height: fit.height)
            let ks = NotchMetrics.kittySize    // the kitty sits inside the right wing
            let kitty = CGRect(x: shape.maxX - NotchMetrics.shoulder - 4 - ks.width, y: h - m.height, width: ks.width, height: m.height)
            return [shape, kitty]
        }
        let mg = Self.margin, bh = fit.height - mg - Self.kitty.height + 5
        return [CGRect(x: mg, y: mg, width: w - 2 * mg, height: bh),
                CGRect(x: w - mg - 30 - Self.kitty.width, y: mg + bh - 5, width: Self.kitty.width, height: Self.kitty.height)]
    }

    func isSolid(_ p: CGPoint) -> Bool { solidRects().contains { $0.contains(p) } }

    func updateMouse() {
        guard let p = panel else { return }
        if NSEvent.pressedMouseButtons != 0 && !p.ignoresMouseEvents { return }   // mid-drag: keep the grab
        let g = NSEvent.mouseLocation, f = p.frame
        let pt = CGPoint(x: g.x - f.minX, y: g.y - f.minY)
        let solid = isSolid(pt)
        if p.ignoresMouseEvents == solid { p.ignoresMouseEvents = !solid }
        handleHover(onShape: solidRects().first?.contains(pt) ?? false, solid: solid, now: CACurrentMediaTime())
    }

    /// Notch mode: open after resting on the shape briefly, close once the mouse has been away a moment.
    func handleHover(onShape: Bool, solid: Bool, now: Double) {
        guard mode == "notch", NSEvent.pressedMouseButtons == 0 else { return }
        let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
        let inside = model.expanded ? solid : onShape
        if inside {
            awaySince = nil
            let since = hoverSince ?? now
            hoverSince = since
            if !model.expanded && now - since >= Self.openDelay { withAnimation(spring) { model.toggle() } }
        } else {
            hoverSince = nil
            let since = awaySince ?? now
            awaySince = since
            if model.expanded && now - since >= Self.closeDelay { withAnimation(spring) { model.toggle() } }
        }
    }

    // --stress out.log [--mode notch|corner] : open/close 60 times like real clicks; record window moves,
    // kitty frame rate and which points catch clicks
    func stress(_ out: String) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let p = panel else { return }
        let home = p.frame, spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
        var lines = [String(format: "stress test  mode=%@  window %.0fx%.0f at (%.0f, %.0f)", mode, home.width, home.height,
                            home.minX, home.minY), ""]
        let phases: [(String, Int, Double)] = [("slow 1s", 10, 1.0), ("normal 0.5s", 10, 0.5), ("fast 0.15s", 20, 0.15), ("spam 0.05s", 20, 0.05)]
        var totalEvents = 0
        for (name, n, gap) in phases {
            frameEvents.removeAll()
            let f0 = kittyFrames, t0 = CACurrentMediaTime()
            for _ in 0..<n {
                withAnimation(spring) { model.toggle() }
                try? await Task.sleep(for: .seconds(gap))
            }
            let fps = Double(kittyFrames - f0) / (CACurrentMediaTime() - t0)
            totalEvents += frameEvents.count
            lines.append(String(format: "%-12@ toggles=%2d  window moves/resizes=%d  kitty %.0f fps", name as NSString, n, frameEvents.count, fps))
        }
        if model.expanded { model.toggle() }
        try? await Task.sleep(for: .seconds(1.2))

        let r = solidRects(), shape = r[0], kitty = r[1]
        var checks: [(String, CGPoint, Bool)] = [
            ("on the shape/bar", CGPoint(x: shape.minX + 30, y: shape.midY), true),
            ("on the kitty", CGPoint(x: kitty.midX, y: kitty.midY), true),
        ]
        if mode == "notch" {
            checks += [("menu bar just left of the notch shape", CGPoint(x: shape.minX - 12, y: p.frame.height - 10), false),
                       ("menu bar just right of the notch shape", CGPoint(x: shape.maxX + 12, y: p.frame.height - 10), false),
                       ("just below the closed notch", CGPoint(x: shape.midX, y: shape.minY - 6), false),
                       ("well below the closed notch", CGPoint(x: shape.minX + 40, y: shape.minY - 60), false)]
        } else {
            checks += [("empty space above the closed bar", CGPoint(x: shape.minX + 60, y: shape.maxY + 80), false),
                       ("shadow margin left of the bar", CGPoint(x: Self.margin / 2, y: shape.midY), false)]
        }
        lines.append("")
        var pass = 0
        for (label, pt, want) in checks {
            let got = isSolid(pt); pass += got == want ? 1 : 0
            lines.append("click \(label): \(got ? "caught" : "passes through")  \(got == want ? "ok" : "WRONG")")
        }

        if mode == "notch" {
            // hover: synthetic mouse positions/times through the same handler real mouse moves use
            func hover(_ onShape: Bool, for secs: Double, from t: Double) -> Double {
                var now = t
                while now < t + secs { handleHover(onShape: onShape, solid: onShape, now: now); now += 0.02 }
                return now
            }
            hoverSince = nil; awaySince = nil
            var t = CACurrentMediaTime()
            t = hover(true, for: 0.05, from: t); t = hover(false, for: 0.5, from: t)
            let brushPast = model.expanded
            t = hover(true, for: 0.2, from: t)
            let opened = model.expanded
            t = hover(false, for: 0.2, from: t)
            let graceHeld = model.expanded
            t = hover(false, for: 0.3, from: t)
            let closed = !model.expanded
            let results = [("brushing past (50 ms) doesn't open", !brushPast), ("resting 200 ms opens", opened),
                           ("stays open for 200 ms after leaving", graceHeld), ("closes after leaving", closed)]
            lines.append("")
            for (label, ok) in results { pass += ok ? 1 : 0; lines.append("hover: \(label)  \(ok ? "ok" : "WRONG")") }
            checks += results.map { ($0.0, .zero, true) }   // count them in the total
            if model.expanded { model.toggle() }
            try? await Task.sleep(for: .seconds(0.6))
        }

        if let m = notch {      // nothing may be cut off by the window's edges, in any state
            let w = p.frame.width
            for (label, width) in [("closed", m.closedWidth(flashing: false)), ("widened for a message", m.closedWidth(flashing: true)),
                                   ("open", NotchMetrics.openWidth)] {
                let ok = width <= w - 2
                pass += ok ? 1 : 0
                checks.append((label, .zero, true))
                lines.append(String(format: "fits in window when %@: %.0f of %.0f pt  %@", label, width, w, ok ? "ok" : "WRONG"))
            }
        }

        // "ready" announcement: widens, then clears itself after ~4s
        model.announce("S02E10 ready")
        try? await Task.sleep(for: .seconds(0.6))
        let wide = solidRects()[0].width
        try? await Task.sleep(for: .seconds(4.5))
        model.load()
        try? await Task.sleep(for: .seconds(0.6))
        let after = solidRects()[0].width
        lines.append(String(format: "announcement: shape %.0f -> %.0f -> %.0f wide, cleared: %@", shape.width, wide, after,
                            model.flashTitle == nil ? "yes" : "NO"))

        lines += ["", String(format: "window moved by (%.1f, %.1f), size unchanged: %@", panel!.frame.minX - home.minX,
                             panel!.frame.minY - home.minY, panel!.frame.size == home.size ? "yes" : "NO"),
                  "TOTAL window moves/resizes=\(totalEvents)  hit checks \(pass)/\(checks.count)"]
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

@MainActor
func snapshot(to path: String) {
    let now = Date()
    func m(expanded: Bool, toggled: Double, petted: Double = 99) -> Model {
        let x = Model(); x.expanded = expanded
        x.toggledAt = now.addingTimeInterval(-toggled); x.pettedAt = now.addingTimeInterval(-petted)
        return x
    }
    let poses: [(String, Model)] = [
        ("idle", m(expanded: false, toggled: 99)),
        ("crouch", m(expanded: true, toggled: 0.07)),
        ("jump", m(expanded: true, toggled: 0.45)),
        ("wave", m(expanded: true, toggled: 1.3)),
        ("yawn", m(expanded: false, toggled: 0.65)),
        ("petted", m(expanded: false, toggled: 99, petted: 0.5)),
    ]
    let view = VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 18) {
            ForEach(poses, id: \.0) { name, model in
                VStack(spacing: 4) {
                    KittyView(model: model, frozenAt: now).scaleEffect(1.6).frame(width: 122, height: 116)
                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        HStack(alignment: .bottom, spacing: 24) {
            BarView(model: m(expanded: false, toggled: 99), kittyAt: now)
            BarView(model: m(expanded: true, toggled: 1.3), kittyAt: now).environment(\.colorScheme, .dark)
        }
    }
    .padding(24).background(Color(white: 0.55))
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

@MainActor
func snapshotNotch(to path: String) {
    let now = Date()
    let m = NotchMetrics.find()?.1 ?? NotchMetrics(notchWidth: 179, height: 32)
    func model(expanded: Bool, toggled: Double = 99, petted: Double = 99, flash: String? = nil) -> Model {
        let x = Model(); x.expanded = expanded; x.flashTitle = flash
        x.toggledAt = now.addingTimeInterval(-toggled); x.pettedAt = now.addingTimeInterval(-petted)
        return x
    }
    func scene(_ label: String, _ x: Model, open: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.62), Color(red: 0.86, green: 0.62, blue: 0.70)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: m.height)          // menu bar
                HStack { Text("  Finder   File   Edit   View").font(.system(size: 12, weight: .medium)); Spacer()
                         Text("Sat 24 Oct  09:52  ").font(.system(size: 12, weight: .medium)) }
                    .foregroundStyle(.white).frame(height: m.height)
                NotchView(model: x, metrics: m, kittyAt: now, measuring: open)
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)    // the physical notch: drawn on top,
                    .fill(Color(white: 0.06)).frame(width: m.notchWidth, height: m.height)  // like the real one hides the screen
            }
            .frame(width: 560, height: open ? 880 : 70)
            .clipped()
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
    }
    let ago = { (s: Double) in now.addingTimeInterval(-s) }
    let moods: [(String, KittyContext)] = [
        ("idle", KittyContext(active: true)), ("fast", KittyContext(active: true, fast: true)),
        ("worried", KittyContext(active: true, worried: true)), ("flagged", KittyContext(alertAt: ago(1))),
        ("all done", KittyContext(celebrateAt: ago(0.9))), ("caught a link", KittyContext(caughtAt: ago(0.45))),
        ("drop here", KittyContext(dropTarget: true)), ("nap", KittyContext(toggledAt: ago(99))),
    ]
    let dropModel = model(expanded: false); dropModel.dropTarget = true
    let offerModel = model(expanded: false); offerModel.offer = "magnet:?xt=urn:btih:abc&dn=Cosmos%20Laundromat"
    let alertModel = model(expanded: false, flash: "⚠ Sample flagged")
    let addedModel = model(expanded: false, flash: "Added Sintel.4K.mkv")
    let view = VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 20) {
                scene("closed", model(expanded: false), open: false)
                scene("download finished", model(expanded: false, flash: "Sintel 4K ready"), open: false)
                scene("dragging a link over it", dropModel, open: false)
                scene("copied a download link", offerModel, open: false)
                scene("link added", addedModel, open: false)
                scene("safety check flagged a torrent", alertModel, open: false)
                HStack(spacing: 6) {
                    ForEach(moods, id: \.0) { name, mood in
                        VStack(spacing: 2) {
                            KittyView(model: model(expanded: false), frozenAt: now, mood: mood)
                                .frame(width: 76, height: 72).background(Color.black).scaleEffect(0.86).frame(width: 66, height: 64)
                            Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
            }
            VStack(spacing: 20) {
                scene("open", model(expanded: true, toggled: 1.3), open: true)

            }
        }
    }
    .padding(20).background(Color(white: 0.35))
    .environment(\.colorScheme, .dark)
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

/// Purrload --render-icon out.png : the 1024px app icon (kitty on lilac), turned into AppIcon.icns by scripts/make-icon.sh
@MainActor
func renderIcon(to path: String) {
    let calm = KittyContext(active: true)     // awake, eyes open
    let icon = ZStack {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.80, green: 0.66, blue: 0.95), Color(red: 0.97, green: 0.80, blue: 0.87)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        UnevenRoundedRectangle(bottomLeadingRadius: 34, bottomTrailingRadius: 34)                  // a little notch
            .fill(Color.black.opacity(0.9)).frame(width: 300, height: 56).offset(y: -384)
        KittyView(model: Model(), frozenAt: Date(timeIntervalSinceReferenceDate: 1.0), mood: calm)
            .scaleEffect(10).frame(width: 760, height: 720).offset(x: -22, y: -28)
    }
    .frame(width: 1024, height: 1024)
    let r = ImageRenderer(content: icon)
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

/// Purrload --selftest out.log : logic checks for drop-to-download (link rules, inbox writing).
@MainActor
func selftest(to path: String) {
    var lines: [String] = [], pass = 0, total = 0
    func check(_ label: String, _ ok: Bool) { total += 1; pass += ok ? 1 : 0; lines.append("\(ok ? "ok   " : "WRONG") \(label)") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("purrload-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let tor = tmp.appendingPathComponent("show.torrent").path
    FileManager.default.createFile(atPath: tor, contents: Data("d4:infod4:name1:aee".utf8))

    check("copied magnet is offered", Links.find(in: "magnet:?xt=urn:btih:abc&dn=Sintel") != nil)
    check("copied link to a .mkv is offered", Links.find(in: "https://example.com/films/Sintel.4K.mkv") != nil)
    check("copied link to a .dmg with a query string is offered", Links.find(in: "https://cdn.example.com/App-2.1.dmg?sig=x") != nil)
    check("copied signed attachment link is offered",
          Links.find(in: "https://r2.example.com/hub/abc?response-content-disposition=attachment%3B%20filename%3D%22a.mkv%22") != nil)
    check("copied ordinary page link is NOT offered", Links.find(in: "https://www.google.com/search?q=cats") == nil)
    check("copied sentence with a link is NOT offered", Links.find(in: "look at https://x.com/a.mkv please") == nil)
    check("copied existing .torrent path is offered", Links.find(in: tor) != nil)
    check("copied missing .torrent path is NOT offered", Links.find(in: "/nope/missing.torrent") == nil)
    check("dropped ordinary page link IS accepted", Links.accept("https://example.com/page") != nil)
    check("dropped plain text is rejected", Links.accept("hello there") == nil)
    check("dropped file that isn't a .torrent is rejected", Links.accept("/Users/x/Documents/notes.txt") == nil)
    check("magnet display name comes from dn=", Links.displayName("magnet:?xt=urn:btih:abc&dn=Sintel%204K") == "Sintel 4K")

    setenv("PURRLOAD_HOME", tmp.path, 1)
    let m = Model()
    m.enqueue("https://example.com/films/Sintel.4K.mkv")
    let inbox = tmp.appendingPathComponent("inbox")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
    check("enqueue writes exactly one inbox file", files.count == 1)
    if let f = files.first, let d = try? Data(contentsOf: inbox.appendingPathComponent(f)),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
        check("inbox file holds the link", obj["url"] == "https://example.com/films/Sintel.4K.mkv")
    } else { check("inbox file holds the link", false) }
    check("no half-written temp files left behind",
          ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).allSatisfy { !$0.hasPrefix(".inbox-") })
    check("kitty catches the link", Date().timeIntervalSince(m.caughtAt) < 1)
    // torrent file picker
    let pickerJSON = """
    {"updated": 0, "speed": 0, "paused": false, "jobs": [{"id": "t1", "name": "Show", "title": "Show", "state": "choosing",
     "done": 0, "total": 0, "speed": 0, "eta": null, "folder": "/tmp", "canRetry": false, "files": [
      {"index": 1, "path": "Show.E01.mkv", "size": 900, "kind": "media", "flags": [], "blocked": false, "preselect": true},
      {"index": 2, "path": "Show.E01.srt", "size": 10, "kind": "subtitle", "flags": [], "blocked": false, "preselect": true},
      {"index": 3, "path": "cover.jpg", "size": 50, "kind": "other", "flags": [], "blocked": false, "preselect": false},
      {"index": 4, "path": "Show.E02.mkv.exe", "size": 5, "kind": "other", "flags": ["double extension"], "blocked": true, "preselect": false}]},
     {"id": "w1", "name": "x", "title": "x", "state": "corrupt", "done": 0, "total": 0, "speed": 0, "eta": null,
      "folder": "/tmp", "canRetry": true, "message": "kept failing"}]}
    """
    let st = try? JSONDecoder().decode(Status.self, from: Data(pickerJSON.utf8))
    check("status with a file list decodes", st?.jobs.first?.files?.count == 4)
    if let st, let tj = st.jobs.first, let files = tj.files {
        m.status = st
        check("media and subtitles are ticked by default, extras aren't", m.selection(for: tj) == [1, 2])
        m.togglePick(files[3], in: tj)
        check("a locked file can't be ticked", !m.selection(for: tj).contains(4))
        m.togglePick(files[2], in: tj)
        check("ticking an extra adds it", m.selection(for: tj) == [1, 2, 3])
        check("selected size adds up", m.pickedBytes(tj) == 960)
        m.pick(tj) { $0.kind != "other" }
        check("'Media only' resets to media + subtitles", m.selection(for: tj) == [1, 2])
        m.pick(tj) { _ in true }
        check("'All safe files' never includes a locked file", m.selection(for: tj) == [1, 2, 3])
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [])
        m.startTorrent(tj)
        m.retry(st.jobs[1]); m.remove(st.jobs[1])
        let added = Set((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).subtracting(before)
        let msgs = added.compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: inbox.appendingPathComponent($0))) as? [String: Any] }
        check("Download sends the picked files", msgs.contains { ($0["select"] as? String) == "t1" && ($0["files"] as? [Int]) == [1, 2, 3] })
        check("Retry and Remove send their requests", msgs.contains { $0["retry"] as? String == "w1" } && msgs.contains { $0["remove"] as? String == "w1" })
    }
    m.offer = "magnet:?xt=urn:btih:abc"; m.offerAt = Date()
    check("offer widens the strip", m.wide)
    m.acceptOffer()
    check("accepting the offer queues it and clears it", m.offer == nil &&
          (((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).count == 5))   // link + select + retry + remove + offer
    try? FileManager.default.removeItem(at: tmp)
    lines += ["", "TOTAL \(pass)/\(total)"]
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

@main
struct PurrloadApp {
    static func main() {
        // Purrload --snapshot out.png : render the expanded bar (light + dark) to an image for checking the design
        useDemoData = CommandLine.arguments.contains("--demo")
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pit-storyboard"), i + 1 < args.count {
            MainActor.assumeIsolated { pitStoryboard(to: args[i + 1]) }
            return
        }
        for (flag, mode) in [("--pit-stress", "stress"), ("--pit-demo", "demo")] {
            if let i = args.firstIndex(of: flag) {
                let arg = i + 1 < args.count ? args[i + 1] : (mode == "demo" ? "all" : "/tmp/pit-stress.log")
                MainActor.assumeIsolated {
                    let app = NSApplication.shared
                    let d = PitToolDelegate(mode: mode, arg: arg)
                    app.delegate = d
                    app.setActivationPolicy(.accessory)
                    withExtendedLifetime(d) { app.run() }
                }
                return
            }
        }
        if CommandLine.arguments.contains("--notify-status") {      // what macOS currently allows Purrload to do
            let done = DispatchSemaphore(value: 0)
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let names = [0: "not decided", 1: "denied", 2: "allowed", 3: "provisional", 4: "ephemeral"]
                print("authorization: \(names[s.authorizationStatus.rawValue] ?? "?")  alerts: \(s.alertSetting.rawValue == 2 ? "on" : "off")  style: \(s.alertStyle.rawValue)")
                done.signal()
            }
            while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { renderIcon(to: CommandLine.arguments[i + 1]) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { selftest(to: CommandLine.arguments[i + 1]) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-notch"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { snapshotNotch(to: CommandLine.arguments[i + 1]) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { snapshot(to: CommandLine.arguments[i + 1]) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}
