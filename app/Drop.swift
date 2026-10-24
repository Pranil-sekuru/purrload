// Drop to download: drag a link, magnet or .torrent onto the notch/bar, or copy one and accept the offer.
// The app only queues the link (a small file in the engine's inbox); the engine does the downloading.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Links {
    static let fileTypes: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "mp3", "flac", "m4a", "srt", "zip", "rar",
                                         "7z", "tar", "gz", "xz", "dmg", "pkg", "iso", "torrent", "pdf", "epub", "apk", "exe", "msi"]

    /// A download link in copied text: a magnet, an existing .torrent file, or a web link that points at a file.
    /// Ordinary page links don't count, so copying a URL to share it doesn't trigger an offer.
    static func find(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 8000, !t.contains(where: { $0.isWhitespace }) else { return nil }
        if t.hasPrefix("magnet:?") { return t }
        if t.hasPrefix("/"), t.lowercased().hasSuffix(".torrent"), FileManager.default.fileExists(atPath: t) { return t }
        guard let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        if fileTypes.contains(u.pathExtension.lowercased()) { return t }
        if t.contains("response-content-disposition=attachment") { return t }   // signed download links
        return nil
    }

    /// Something dropped on purpose: any web link counts, as well as magnets and .torrent files.
    static func accept(_ text: String) -> String? {
        if let l = find(in: text) { return l }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil { return t }
        return nil
    }

    static func displayName(_ link: String) -> String {
        if link.hasPrefix("magnet:") {
            return URLComponents(string: link)?.queryItems?.first { $0.name == "dn" }?.value ?? "magnet link"
        }
        if link.hasPrefix("/") { return URL(fileURLWithPath: link).lastPathComponent }
        if let u = URL(string: link), u.lastPathComponent.count > 1 { return u.lastPathComponent }
        return URL(string: link)?.host ?? "link"
    }
}

extension Model {
    /// Queue a link for the engine (write to a temp file, then move it in, so the engine never reads half a file).
    func enqueue(_ link: String) {
        let fm = FileManager.default
        let inbox = base.appendingPathComponent("inbox")
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let tmp = base.appendingPathComponent(".inbox-\(UUID().uuidString)")
        let file = inbox.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json")
        guard let data = try? JSONSerialization.data(withJSONObject: ["url": link]),
              (try? data.write(to: tmp)) != nil, (try? fm.moveItem(at: tmp, to: file)) != nil else {
            announce("Couldn't add that")
            return
        }
        caughtAt = Date()
        let name = Links.displayName(link)
        announce(guardRunning ? "Added \(name.prefix(22))" : "Queued, engine is off")
    }

    func acceptOffer() {
        guard let o = offer else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { offer = nil }
        enqueue(o)
    }

    func dismissOffer() { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { offer = nil } }

    /// Called every second: offer to download a link that was just copied.
    func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != clipboardChange else { return }
        clipboardChange = pb.changeCount
        guard watchClipboard, let s = pb.string(forType: .string), let link = Links.find(in: s), link != offer else { return }
        offerAt = Date()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { offer = link }
    }
}

/// Drop target for the notch and the corner bar.
struct LinkDrop: DropDelegate {
    let model: Model
    static let types: [UTType] = [.fileURL, .url, .plainText]

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.dropTarget = true } }
    func dropExited(info: DropInfo) { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.dropTarget = false } }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation { model.dropTarget = false }
        guard let item = info.itemProviders(for: Self.types).first else { return false }
        let model = self.model
        let handle: @Sendable (String?) -> Void = { text in
            Task { @MainActor in
                if let text, let link = Links.accept(text) { model.enqueue(link) } else { model.announce("Not a download link") }
            }
        }
        if item.canLoadObject(ofClass: URL.self) {
            _ = item.loadObject(ofClass: URL.self) { url, _ in handle(url.map { $0.isFileURL ? $0.path : $0.absoluteString }) }
        } else {
            _ = item.loadObject(ofClass: String.self) { s, _ in handle(s) }
        }
        return true
    }
}

/// Drop target only on live views: snapshot/measuring copies skip it (the image renderer can't draw it).
struct LinkDropTarget: ViewModifier {
    let model: Model
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.onDrop(of: LinkDrop.types, delegate: LinkDrop(model: model)) } else { content }
    }
}

/// "Download this?" row shown at the top of the open notch / bar when a link was copied.
struct OfferRow: View {
    @ObservedObject var model: Model
    var body: some View {
        if let link = model.offer {
            VStack(alignment: .leading, spacing: 6) {
                Text("COPIED A DOWNLOAD LINK").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.soft).tracking(0.6)
                Text(Links.displayName(link)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 16) {
                    Button("Download") { model.acceptOffer() }.foregroundStyle(Color.lilac)
                    Button("Ignore") { model.dismissOffer() }.foregroundStyle(Color.soft)
                }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold))
            }
        }
    }
}
