// Keeps the engine alive without any app owning it. An engine started from a terminal or another app dies when that
// app quits; a launchd agent starts it at login and restarts it if it stops. Purrload asks once, then copies the
// bundled engine to Application Support (a path that survives moving the app) and registers
// ~/Library/LaunchAgents/<label>.plist. scripts/install-engine-agent.sh does the same from a checkout, and its
// --remove undoes either.
import SwiftUI
import AppKit
import ServiceManagement

struct AgentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum EngineAgent {
    static let label = "io.github.pranil-sekuru.purrload-engine"
    static let python = "/usr/bin/python3"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static func engineCopy(_ base: URL) -> URL { base.appendingPathComponent("engine/purrload-engine.py") }
    static var bundledEngine: URL? { Bundle.main.url(forResource: "purrload-engine", withExtension: "py") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func plistData(base: URL, engine: URL) throws -> Data {
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]   // where aria2 usually lives
        if ProcessInfo.processInfo.environment["PURRLOAD_HOME"] != nil { env["PURRLOAD_HOME"] = base.path }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [python, "-I", engine.path],
            "EnvironmentVariables": env,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": base.appendingPathComponent("crash.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Put the bundled engine where launchd will run it. Returns the copy's path.
    @discardableResult
    static func copyEngine(base: URL) throws -> URL {
        guard let bundled = bundledEngine else { throw AgentError("This build of Purrload has no engine inside it.") }
        let dest = engineCopy(base)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: bundled)
        if (try? Data(contentsOf: dest)) != data { try data.write(to: dest, options: .atomic) }
        return dest
    }

    /// After an app update: bring the copy up to date. A running engine keeps its old code until its next restart,
    /// so a download is never interrupted for this.
    static func refreshCopy(base: URL) {
        guard isInstalled else { return }
        _ = try? copyEngine(base: base)
    }

    /// Takes a while (it waits for an engine started by hand to stop), so call it off the main thread.
    static func install(base: URL) throws {
        let engine = try copyEngine(base: base)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plistData(base: base, engine: engine).write(to: plistURL, options: .atomic)
        let domain = "gui/\(getuid())"
        run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])         // an earlier copy of this agent, if any
        // an engine somebody started by hand: it saves its downloads when asked to stop, and the new one picks them up
        run("/usr/bin/pkill", ["-TERM", "-f", "purrload-engine.py"])
        for _ in 0..<60 where run("/usr/bin/pgrep", ["-f", "purrload-engine.py"]).status == 0 { Thread.sleep(forTimeInterval: 1) }
        let r = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if r.status != 0 { throw AgentError("launchctl said: \(r.out)") }
    }

    /// Open Purrload itself at login too, so the notch is back after a restart without anyone starting it.
    static func openAppAtLogin() throws {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
    }
}

@MainActor
enum EngineAgentPrompt {
    /// Ask once whether to run on its own: the engine as a launchd agent, the app as a login item.
    /// After a "Not now" it asks again only if the engine isn't running.
    static func askIfNeeded(model: Model) {
        let needAgent = !EngineAgent.isInstalled, needApp = SMAppService.mainApp.status != .enabled
        guard needAgent || needApp, EngineAgent.bundledEngine != nil else { return }
        if UserDefaults.standard.bool(forKey: "engineAgentDeclined") && model.guardRunning { return }

        let alert = NSAlert()
        alert.messageText = "Keep Purrload running on its own?"
        alert.informativeText = "Purrload downloads through a small helper in the background. If Purrload opens at login "
            + "and the helper restarts itself when it stops, downloads keep going after you quit other apps or restart "
            + "your Mac. You can turn it off any time in System Settings › General › Login Items & Extensions."
        alert.addButton(withTitle: "Turn on")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "engineAgentDeclined")
            return
        }
        UserDefaults.standard.removeObject(forKey: "engineAgentDeclined")
        var problems: [String] = []
        do { try EngineAgent.openAppAtLogin() } catch { problems.append("Opening at login: \(error.localizedDescription)") }
        if !needAgent { return report(problems, model: model) }
        model.announce("Starting the engine…")
        let base = model.base
        Task.detached {
            let result = Result { try EngineAgent.install(base: base) }
            await MainActor.run {
                if case .failure(let e) = result { problems.append("The engine: \(e.localizedDescription)") }
                report(problems, model: model)
            }
        }
    }

    static func report(_ problems: [String], model: Model) {
        guard !problems.isEmpty else { return model.announce("Purrload will keep running") }
        let fail = NSAlert()
        fail.messageText = "Couldn't turn it all on"
        fail.informativeText = problems.joined(separator: "\n")
        fail.runModal()
    }
}
