// Choosing what to download from a torrent, and the small buttons under each download.
import SwiftUI

/// Every file in the torrent with a tick box. Media is ticked by default; files the safety check
/// flagged are locked (shown with the reason) and can't be picked here.
struct FilePicker: View {
    @ObservedObject var model: Model
    let job: Job

    var body: some View {
        let files = job.files ?? []
        let picked = model.selection(for: job)
        VStack(alignment: .leading, spacing: 8) {
            let list = VStack(alignment: .leading, spacing: 6) {
                ForEach(files) { f in FileRow(file: f, picked: picked.contains(f.index)) { model.togglePick(f, in: job) } }
            }
            if files.count > 7 {        // long torrents scroll; short lists just show (no scroll bar)
                ScrollView { list.padding(.vertical, 2) }.frame(height: 190)
            } else {
                list
            }

            HStack(spacing: 6) {
                Text("Save to").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.soft)
                FolderChip(model: model, job: job)
            }
            HStack(spacing: 14) {
                Button("Download \(picked.count) · \(gb(model.pickedBytes(job)))") { model.startTorrent(job) }
                    .foregroundStyle(picked.isEmpty ? Color.soft : Color.lilac)
                    .disabled(picked.isEmpty)
                Button("Media only") { model.pick(job) { $0.kind != "other" } }.foregroundStyle(Color.soft)
                Button("All safe files") { model.pick(job) { _ in true } }.foregroundStyle(Color.soft)
                Spacer()
                Button("Cancel") { model.remove(job) }.foregroundStyle(Color.soft)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
        }
    }
}

struct FileRow: View {
    let file: TorrentFile
    let picked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: file.blocked ? "nosign" : picked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(file.blocked ? Color.gem : picked ? Color.lilac : Color.soft)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path).font(.system(size: 11.5)).foregroundStyle(file.blocked ? Color.soft : Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                if !file.flags.isEmpty {
                    Text((file.blocked ? "⚠ locked: " : "") + file.flags.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(file.blocked ? Color.gem : Color(red: 0.92, green: 0.66, blue: 0.3))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(gb(file.size)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color.soft)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .help(file.blocked ? "Locked by the safety check" : picked ? "Don't download this" : "Download this")
    }
}

/// Retry / Show in Finder / Remove, depending on how the download ended.
struct RowActions: View {
    @ObservedObject var model: Model
    let job: Job

    var body: some View {
        let finished = job.state == "verified", failed = job.canRetry == true
        let flagged = job.state == "danger" || job.state == "expired" || (job.state == "corrupt" && !failed)
        if finished || failed || flagged {
            HStack(spacing: 14) {
                if failed { Button("Retry") { model.retry(job) }.foregroundStyle(Color.lilac) }
                if finished || job.state == "danger" { Button("Show in Finder") { model.reveal(job) }.foregroundStyle(Color.lilac) }
                Button("Remove") { model.remove(job) }.foregroundStyle(Color.soft)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
        }
    }
}
