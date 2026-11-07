import AppKit
import SousCore

/// Connects SousBar to Claude Code from inside the app, so a drag-installed app (from the DMG)
/// works without running install.sh. The actual settings.json editing is done by the hook's own
/// `install` / `uninstall` commands, the same code install.sh uses, after a backup.
enum HookConnection {
    /// The hook binary shipped inside SousBar.app (Contents/MacOS/sousbar-hook).
    static var bundledHook: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("sousbar-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var isConnected: Bool { HookSetup.isInstalled() }

    /// At every launch: if already connected, make sure the installed hook matches this app's
    /// version (an updated app brings an updated hook). Never connects on its own.
    static func syncIfConnected() {
        guard isConnected, let bundled = bundledHook else { return }
        do {
            if try HookSetup.syncBinary(from: bundled, to: SousPaths.hookBinary) {
                NSLog("SousBar: updated the installed hook from the app bundle")
            }
        } catch {
            NSLog("SousBar: couldn't update the installed hook: \(error)")
        }
    }

    /// Installs the hook binary and adds the hooks to ~/.claude/settings.json. Returns what happened.
    static func connect() -> (ok: Bool, message: String) {
        guard let bundled = bundledHook else {
            return (false, "This copy of SousBar has no hook inside it. Install it with install.sh instead.")
        }
        do {
            try HookSetup.syncBinary(from: bundled, to: SousPaths.hookBinary)
        } catch {
            return (false, "Couldn't install the hook: \(error)")
        }
        return run(SousPaths.hookBinary, "install")
    }

    /// Removes our hooks from ~/.claude/settings.json (after a backup). Leaves the files.
    static func disconnect() -> (ok: Bool, message: String) {
        let hook = FileManager.default.isExecutableFile(atPath: SousPaths.hookBinary) ? SousPaths.hookBinary : bundledHook
        guard let hook else { return (false, "Couldn't find sousbar-hook to remove the hooks.") }
        return run(hook, "uninstall")
    }

    private static func run(_ path: String, _ argument: String) -> (ok: Bool, message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [argument]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (false, "Couldn't run sousbar-hook: \(error.localizedDescription)")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, output)
    }

    // MARK: - Asking

    /// First launch of a drag-installed app: ask once. "Not now" isn't asked again; the menu
    /// bar's "Connect to Claude Code…" is always there.
    static func offerIfNeeded() {
        guard !isConnected, bundledHook != nil, !Settings.declinedHookSetup else { return }
        askToConnect(firstTime: true)
    }

    static func askToConnect(firstTime: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Connect SousBar to Claude Code?"
        alert.informativeText = """
        SousBar adds its hooks to ~/.claude/settings.json (backing the file up first) and puts a \
        small helper in ~/.sousbar. Nothing else in your settings changes.

        Restart any running Claude Code sessions afterwards so they load the hooks.
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: firstTime ? "Not Now" : "Cancel")
        NSApp.activate(ignoringOtherApps: true) // an accessory app's alert must come to the front to be seen
        guard alert.runModal() == .alertFirstButtonReturn else {
            if firstTime { Settings.declinedHookSetup = true }
            return
        }
        report(connect(), success: "Connected. Restart running Claude Code sessions to start using SousBar.")
    }

    static func askToDisconnect() {
        let alert = NSAlert()
        alert.messageText = "Disconnect SousBar from Claude Code?"
        alert.informativeText = "Removes SousBar's hooks from ~/.claude/settings.json (backing it up first). Claude Code works exactly as before. You can connect again from this menu."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        report(disconnect(), success: "Disconnected. To remove SousBar completely, quit it and move it to the Trash, then delete ~/.sousbar.")
    }

    private static func report(_ result: (ok: Bool, message: String), success: String) {
        let alert = NSAlert()
        alert.alertStyle = result.ok ? .informational : .warning
        alert.messageText = result.ok ? success : "That didn't work"
        alert.informativeText = result.message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
