// The cat-folder chip that picks where downloads go; saved for the engine in settings.json.
import SwiftUI
import AppKit

extension Model {
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path

    var downloadFolder: String {
        // --demo shows the default, never your own folders (screenshots go in the README)
        get { useDemoData ? Model.defaultFolder : UserDefaults.standard.string(forKey: "downloadFolder") ?? Model.defaultFolder }
        set {
            UserDefaults.standard.set(newValue, forKey: "downloadFolder")
            var recent = recentFolders.filter { $0 != newValue }
            recent.insert(newValue, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(5)), forKey: "recentFolders")
            writeSettings()
            objectWillChange.send()
        }
    }

    var recentFolders: [String] {
        useDemoData ? [Model.defaultFolder] : UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [Model.defaultFolder]
    }

    func writeSettings() {
        guard let data = try? JSONSerialization.data(withJSONObject: ["downloadFolder": downloadFolder]) else { return }
        try? data.write(to: base.appendingPathComponent("settings.json"), options: .atomic)
    }

    func setFolder(_ path: String) {
        downloadFolder = path
        caughtAt = Date()
        announce("Saving to \(Folders.name(path).prefix(20))")
    }

    /// Where a torrent will go: chosen just for it; else the folder you picked; else ~/Downloads/Torrents.
    func torrentFolder(for j: Job) -> String {
        if let f = torrentFolders[j.id] { return f }
        return downloadFolder == Model.defaultFolder ? (downloadFolder as NSString).appendingPathComponent("Torrents") : downloadFolder
    }
}

enum Folders {
    /// "Downloads", or "Backup Plus › Movies" for a folder on another drive.
    static func name(_ path: String) -> String {
        let parts = (path as NSString).standardizingPath.split(separator: "/").map(String.init)
        let last = FileManager.default.displayName(atPath: path)
        if parts.count >= 2, parts[0] == "Volumes" {
            return parts.count == 2 ? parts[1] : "\(parts[1]) › \(last)"
        }
        return last
    }

    static func isUnplugged(_ path: String) -> Bool {
        let parts = (path as NSString).standardizingPath.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        var isDir: ObjCBool = false
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])", isDirectory: &isDir)
    }

    /// The standard macOS folder picker (non-modal, so the notch keeps animating).
    @MainActor
    static func choose(startingAt path: String, done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save here"
        panel.message = "Where should Purrload put your downloads?"
        panel.directoryURL = URL(fileURLWithPath: path)
        NSApp.activate(ignoringOtherApps: true)        // Purrload has no Dock icon; bring the picker to the front
        panel.begin { response in
            if response == .OK, let url = panel.url { done(url.path) }
        }
    }
}

@MainActor
final class FolderMenu: NSObject {
    static let shared = FolderMenu()
    private var pick: ((String) -> Void)?
    private var current = ""

    func show(current: String, recent: [String], pick: @escaping (String) -> Void) {
        self.pick = pick
        self.current = current
        let menu = NSMenu()
        let title = NSMenuItem(title: "Save downloads to", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for path in ([current] + recent.filter { $0 != current }).prefix(5) {
            let item = NSMenuItem(title: Folders.name(path) + (Folders.isUnplugged(path) ? "  (not connected)" : ""),
                                  action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = path == current ? .on : .off
            item.image = NSImage(systemSymbolName: path.hasPrefix("/Volumes/") ? "externaldrive" : "folder", accessibilityDescription: nil)
            item.toolTip = path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Choose another folder…", action: #selector(chooseOther), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func choose(_ item: NSMenuItem) {
        if let p = item.representedObject as? String { pick?(p) }
    }
    @objc private func chooseOther() {
        let pick = self.pick
        Folders.choose(startingAt: current) { path in pick?(path) }
    }
    @objc private func showInFinder() {
        try? FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: current))
    }
}

/// A lilac folder with cat ears, eyes and a little "w" mouth. Shapes only.
struct CatFolderIcon: View {
    var size: CGFloat = 18
    var body: some View {
        Canvas { c, s in
            let k = s.width / 18
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let lilac = Color(red: 0.76, green: 0.6, blue: 0.95), deep = Color(red: 0.55, green: 0.4, blue: 0.78)
            let line = Color(red: 0.29, green: 0.23, blue: 0.37)
            for (a, b, tip) in [(p(3.2, 6), p(7, 6), p(4.2, 1.6)), (p(11, 6), p(14.8, 6), p(13.8, 1.6))] {   // ears
                var ear = Path(); ear.move(to: a); ear.addLine(to: tip); ear.addLine(to: b); ear.closeSubpath()
                c.fill(ear, with: .color(deep))
            }
            var tab = Path()                                                          // folder tab + back
            tab.addRoundedRect(in: CGRect(origin: p(1, 4.6), size: CGSize(width: 7 * k, height: 4 * k)), cornerSize: CGSize(width: 1.5 * k, height: 1.5 * k))
            c.fill(tab, with: .color(deep))
            let front = Path(roundedRect: CGRect(origin: p(1, 6.4), size: CGSize(width: 16 * k, height: 10.4 * k)), cornerRadius: 2.4 * k)
            c.fill(front, with: .color(lilac))
            for x: CGFloat in [6.3, 11.7] {                                           // eyes
                c.fill(Path(ellipseIn: CGRect(origin: p(x - 0.9, 9.6), size: CGSize(width: 1.8 * k, height: 2.2 * k))), with: .color(line))
            }
            var w = Path()                                                            // the little "w" mouth
            w.move(to: p(7.4, 13)); w.addQuadCurve(to: p(9, 13), control: p(8.2, 14.2))
            w.addQuadCurve(to: p(10.6, 13), control: p(9.8, 14.2))
            c.stroke(w, with: .color(line), style: StrokeStyle(lineWidth: 0.9 * k, lineCap: .round))
            for x: CGFloat in [4.4, 13.6] {                                           // blush
                c.fill(Path(ellipseIn: CGRect(origin: p(x - 1.2, 11.6), size: CGSize(width: 2.4 * k, height: 1.4 * k))),
                       with: .color(Color(red: 0.96, green: 0.64, blue: 0.71).opacity(0.8)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// "🐱📁 Downloads ▾" — click to pick where downloads go. With `job`, it picks a folder just for that torrent.
struct FolderChip: View {
    @ObservedObject var model: Model
    var job: Job? = nil
    var prefix = ""

    var path: String { job.map { model.torrentFolder(for: $0) } ?? model.downloadFolder }

    var body: some View {
        Button {
            let id = job?.id
            FolderMenu.shared.show(current: path, recent: model.recentFolders) { chosen in
                if let id { model.torrentFolders[id] = chosen; model.caughtAt = Date() } else { model.setFolder(chosen) }
            }
        } label: {
            HStack(spacing: 5) {
                CatFolderIcon(size: 17)
                Text(prefix + Folders.name(path)).lineLimit(1).truncationMode(.middle)
                if Folders.isUnplugged(path) {
                    Text("not connected").foregroundStyle(Color.gem)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.soft)
            }
            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.lilac.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color.lilac)
        .help(path)
    }
}
