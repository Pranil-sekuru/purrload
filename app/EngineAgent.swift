// The engine runs either under launchd (opt-in: starts at login, restarted if it stops) or as the app's child
// while the app is open. Always from inside the signed app, and only if the app's signature is intact.
import SwiftUI
import AppKit
import ServiceManagement
import Security

struct AgentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum EngineAgent {
    static let label = "io.github.pranil-sekuru.purrload-engine"
    static let python = "/usr/bin/python3"
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var bundledEngine: URL? { Bundle.main.url(forResource: "purrload-engine", withExtension: "py", subdirectory: "engine") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Older versions ran a copy in Application Support.
    static var installedEnginePath: String? {
        guard let d = try? Data(contentsOf: plistURL),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return (p["ProgramArguments"] as? [String])?.last
    }

    /// False if any file in the app (the engine included) changed after it was signed.
    static var appIsIntact: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }

    static func engine() throws -> URL {
        guard let e = bundledEngine else { throw AgentError("This build of Purrload has no engine inside it.") }
        guard appIsIntact else {
            throw AgentError("Purrload's files were changed after it was built, so its engine won't run. Reinstall Purrload.")
        }
        return e
    }

    static func plistData(base: URL, engine: URL) throws -> Data {
        var env = ["PATH": path]
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

    /// Waits, because aria2 can be slow to let go of a USB drive.
    static func stopEngines() {
        run("/usr/bin/pkill", ["-TERM", "-f", "purrload-engine.py"])
        for _ in 0..<60 where run("/usr/bin/pgrep", ["-f", "purrload-engine.py"]).status == 0 { Thread.sleep(forTimeInterval: 1) }
    }

    /// Slow: call it off the main thread.
    static func install(base: URL) throws {
        let engine = try engine()
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plistData(base: base, engine: engine).write(to: plistURL, options: .atomic)
        let domain = "gui/\(getuid())"
        run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        stopEngines()
        let r = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if r.status != 0 { throw AgentError("launchctl said: \(r.out)") }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("engine"))   // the copy older versions ran
    }

    /// Slow: call it off the main thread.
    static func remove() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        stopEngines()
    }

    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    // MARK: running with the app, when the agent is off

    nonisolated(unsafe) static var child: Process?

    static func startWithApp(base: URL) {
        guard !isInstalled, child?.isRunning != true, let engine = try? engine() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", engine.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path                // opened from Finder the app has no Homebrew on its PATH, so no aria2
        env["PURRLOAD_HOME"] = base.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        let log = base.appendingPathComponent("crash.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); p.standardError = h }
        if (try? p.run()) != nil { child = p }    // if an engine is already running, this one exits at once (its lock)
    }

    static func stopWithApp() {
        child?.terminate()
        child = nil
    }

    // MARK: kept up to date while the app runs

    nonisolated(unsafe) static var working = false
    nonisolated(unsafe) static var warnedTampered = false

    /// Re-pointing an old agent restarts the engine, so it waits until nothing is downloading.
    @MainActor
    static func maintain(model: Model) {
        guard !working else { return }
        if bundledEngine != nil && !appIsIntact {
            if isInstalled { working = true; Task.detached { remove(); working = false } }
            if !warnedTampered {
                warnedTampered = true
                let a = NSAlert()
                a.messageText = "Purrload's engine is turned off"
                a.informativeText = "Purrload's files were changed after it was built, so it won't run its engine. "
                    + "Reinstall Purrload to fix this."
                a.runModal()
            }
            return
        }
        if !isInstalled { return startWithApp(base: model.base) }
        if let e = bundledEngine?.path, installedEnginePath != e, model.activeJobs.isEmpty {
            working = true
            let base = model.base
            Task.detached { try? install(base: base); working = false }
        }
    }

    /// Downloaded files are left alone. Slow: call it off the main thread.
    static func uninstall(base: URL) {
        remove()
        try? SMAppService.mainApp.unregister()
        try? FileManager.default.removeItem(at: base)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }
}

@MainActor
enum EngineAgentPrompt {
    /// Asks once; after "Not now" the right-click menu is the way to turn it on.
    static func askIfNeeded(model: Model) {
        let needAgent = !EngineAgent.isInstalled, needApp = !EngineAgent.opensAtLogin
        guard needAgent || needApp, EngineAgent.bundledEngine != nil, EngineAgent.appIsIntact else { return }
        if UserDefaults.standard.object(forKey: "engineAgentDeclined") != nil { return }

        let alert = NSAlert()
        alert.messageText = "Keep Purrload running on its own?"
        alert.informativeText = "Purrload downloads through a small helper. If Purrload opens at login and the helper keeps "
            + "running in the background, downloads carry on after you quit apps or restart your Mac.\n\n"
            + "Not now: downloads run only while Purrload is open. You can change this any time: right-click Purrload › "
            + "Background engine."
        alert.addButton(withTitle: "Turn on")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "engineAgentDeclined")
            return
        }
        var problems: [String] = []
        do { try EngineAgent.setOpensAtLogin(true) } catch { problems.append("Opening at login: \(error.localizedDescription)") }
        if !needAgent { return report(problems, model: model) }
        setAgent(true, model: model, problems: problems)
    }

    static func setAgent(_ on: Bool, model: Model, problems: [String] = []) {
        var problems = problems
        model.announce(on ? "Starting the engine…" : "Engine runs while Purrload is open")
        let base = model.base
        EngineAgent.working = true
        Task.detached {
            let failure: String?
            if on {
                do { try EngineAgent.install(base: base); failure = nil } catch { failure = "The engine: \(error.localizedDescription)" }
            } else { EngineAgent.remove(); failure = nil }
            await MainActor.run {
                EngineAgent.working = false
                if let failure { problems.append(failure) }
                if !on { EngineAgent.startWithApp(base: base) }
                report(problems, model: model, done: on ? "Purrload will keep running" : nil)
            }
        }
    }

    static func setOpensAtLogin(_ on: Bool, model: Model) {
        do { try EngineAgent.setOpensAtLogin(on) } catch { report(["Opening at login: \(error.localizedDescription)"], model: model) }
        model.objectWillChange.send()
    }

    static func report(_ problems: [String], model: Model, done: String? = "Purrload will keep running") {
        guard !problems.isEmpty else { if let done { model.announce(done) }; return }
        let fail = NSAlert()
        fail.messageText = "Couldn't turn it all on"
        fail.informativeText = problems.joined(separator: "\n")
        fail.runModal()
    }

    static func confirmUninstall(model: Model) {
        let a = NSAlert()
        a.messageText = "Uninstall Purrload?"
        let n = model.activeJobs.count
        a.informativeText = (n > 0 ? "\(n) download\(n == 1 ? "" : "s") will stop. " : "")
            + "This stops the engine, removes it from login, deletes Purrload's settings and download list, and moves "
            + "the app to the Bin. Files you downloaded stay where they are."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        model.announce("Uninstalling…")
        let base = model.base
        EngineAgent.working = true
        EngineAgent.stopWithApp()
        Task.detached {
            EngineAgent.uninstall(base: base)
            await MainActor.run {
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in NSApp.terminate(nil) }
            }
        }
    }
}

struct EngineMenu: View {
    @ObservedObject var model: Model
    var body: some View {
        Menu("Background engine") {
            let agent = EngineAgent.isInstalled
            Button((agent ? "✓ " : "") + "Keep downloading after Purrload quits") {
                EngineAgentPrompt.setAgent(!agent, model: model)
            }
            let login = EngineAgent.opensAtLogin
            Button((login ? "✓ " : "") + "Open Purrload at login") { EngineAgentPrompt.setOpensAtLogin(!login, model: model) }
            Divider()
            Button("Uninstall Purrload…") { EngineAgentPrompt.confirmUninstall(model: model) }
        }
    }
}
