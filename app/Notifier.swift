// Notifications come from Purrload itself (its name and icon), not from AppleScript/Script Editor.
// The engine lists them in status.json as "events"; the app posts each new one once.
import AppKit
import UserNotifications

struct EngineEvent: Decodable {
    let id: Int
    let title: String
    let body: String
    var path: String? = nil
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var lastSeen: Int?          // nil until the first status read: events from before launch aren't replayed

    private var base: URL?

    func start(logTo base: URL) {
        self.base = base
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in   // the user can change it in System Settings
            Task { @MainActor in Notifier.shared.publishPermission() }
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // Recorded so "why don't I get notifications?" has an answer (see app.log in the data folder).
            let line = "\(Date()) notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \($0.localizedDescription)" } ?? "")\n"
            let log = base.appendingPathComponent("app.log")
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: log, atomically: true, encoding: .utf8) }
            Task { @MainActor in Notifier.shared.publishPermission() }
        }
    }

    /// Tell the engine whether Purrload may show notifications: if not, the engine falls back to AppleScript.
    func publishPermission() {
        guard let base else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized && s.alertSetting == .enabled
            try? (ok ? "allowed" : "not allowed").write(to: base.appendingPathComponent("notifications"), atomically: true, encoding: .utf8)
        }
    }

    /// Called with each status update; posts events newer than the last one seen.
    func handle(_ events: [EngineEvent]) {
        let newest = events.map(\.id).max() ?? 0
        guard let last = lastSeen else { lastSeen = newest; return }
        for e in events where e.id > last { post(e) }
        lastSeen = max(last, newest)
    }

    func post(_ e: EngineEvent) {
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.body
        content.sound = .default
        if let p = e.path { content.userInfo = ["path": p] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "purrload-\(e.id)", content: content, trigger: nil))
    }

    // Show banners even though Purrload counts as the active app while its notch is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // Clicking "Download complete" shows the file in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        if let p = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: p) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            }
        }
        done()
    }
}
