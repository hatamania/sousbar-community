import AppKit

/// Types into a Claude Code session, or brings it to the front.
/// Typing never activates anything: tmux send-keys and iTerm2's `write text`
/// both work while the terminal stays in the background.
enum TerminalBridge {
    private static func tmuxPath() -> String? {
        ["/usr/local/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> (String?, String?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
        }
        return (result?.stringValue, nil)
    }

    /// Returns an error message, or nil on success.
    static func send(_ text: String, to terminal: TerminalInfo) -> String? {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        if terminal.usesTmux, let pane = terminal.tmuxPane, let socket = terminal.tmuxSocket {
            guard let tmux = tmuxPath() else { return "tmux not found in /usr/local/bin or /opt/homebrew/bin" }
            guard run(tmux, ["-S", socket, "send-keys", "-t", pane, "-l", "--", clean]) == 0 else {
                return "tmux couldn't reach that pane"
            }
            usleep(150_000)
            run(tmux, ["-S", socket, "send-keys", "-t", pane, "Enter"])
            return nil
        }
        if let uuid = terminal.itermUUID {
            let script = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(appleScriptEscape(uuid))" then
                                tell s to write text "\(appleScriptEscape(clean))"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
            let (result, error) = runAppleScript(script)
            if let error { return "iTerm2: \(error)" }
            return result == "ok" ? nil : "That iTerm2 session is gone"
        }
        return "Voice needs tmux or iTerm2 for this session"
    }

    private static let bundleIds: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "vscode": "com.microsoft.VSCode",
    ]

    // MARK: - New session

    /// How a new Claude Code session gets opened, chosen from a nearby session's terminal.
    enum NewSessionPlan: Equatable {
        case tmux(socket: String)          // new background window in the same tmux server
        case iterm(nearSession: String?)   // new tab next to that iTerm2 session (or in the first window)
        case terminalApp                   // new Terminal.app window
    }

    static func plan(for terminal: TerminalInfo?) -> NewSessionPlan {
        if let t = terminal, t.usesTmux, let socket = t.tmuxSocket { return .tmux(socket: socket) }
        if let t = terminal, t.itermUUID != nil || t.termProgram == "iTerm.app" { return .iterm(nearSession: t.itermUUID) }
        return .terminalApp
    }

    /// 'it'\''s' style single-quoting for the shell.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What gets typed into the new tab: go to the folder and start Claude Code.
    static func startCommand(in folder: String) -> String {
        "cd \(shellQuote(folder)) && claude"
    }

    /// Opens a new terminal tab/window in `folder` running `claude`, without bringing anything to
    /// the front. Returns an error message, or nil on success.
    static func newSession(in folder: String, like terminal: TerminalInfo?) -> String? {
        guard FileManager.default.fileExists(atPath: folder) else { return "That folder doesn't exist any more" }
        let command = startCommand(in: folder)
        switch plan(for: terminal) {
        case let .tmux(socket):
            guard let tmux = tmuxPath() else { return "tmux not found in /usr/local/bin or /opt/homebrew/bin" }
            // A shell window (so your PATH is set up), then type the command into it.
            let target = "sousbar-\(Int(Date().timeIntervalSince1970))"
            guard run(tmux, ["-S", socket, "new-window", "-d", "-n", target, "-c", folder]) == 0 else {
                return "tmux couldn't open a new window"
            }
            run(tmux, ["-S", socket, "send-keys", "-t", target, "-l", "--", "claude"])
            run(tmux, ["-S", socket, "send-keys", "-t", target, "Enter"])
            return nil

        case let .iterm(near):
            let match = near.map { """
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(appleScriptEscape($0))" then set target to w
                        end repeat
                    end repeat
                end repeat
            """ } ?? ""
            let script = """
            tell application id "com.googlecode.iterm2"
                set target to missing value
                \(match)
                if target is missing value then
                    if (count of windows) is 0 then
                        set newWindow to (create window with default profile)
                        tell current session of newWindow to write text "\(appleScriptEscape(command))"
                        return "ok"
                    end if
                    set target to first window
                end if
                tell target
                    set newTab to (create tab with default profile)
                    tell current session of newTab to write text "\(appleScriptEscape(command))"
                end tell
                return "ok"
            end tell
            """
            let (_, error) = runAppleScript(script)
            return error.map { "iTerm2: \($0)" }

        case .terminalApp:
            let script = """
            tell application id "com.apple.Terminal" to do script "\(appleScriptEscape(command))"
            """
            let (_, error) = runAppleScript(script)
            return error.map { "Terminal: \($0)" }
        }
    }

    /// The only thing in the app that switches what's on your screen.
    static func jump(to terminal: TerminalInfo) {
        if terminal.usesTmux, let pane = terminal.tmuxPane, let socket = terminal.tmuxSocket, let tmux = tmuxPath() {
            run(tmux, ["-S", socket, "select-window", "-t", pane])
            run(tmux, ["-S", socket, "select-pane", "-t", pane])
        }
        if let uuid = terminal.itermUUID {
            let script = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(appleScriptEscape(uuid))" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
            if runAppleScript(script).1 == nil { return }
        }
        let bundleId = terminal.bundleId ?? terminal.termProgram.flatMap { bundleIds[$0] }
        if let bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [.activateAllWindows])
        }
    }
}
