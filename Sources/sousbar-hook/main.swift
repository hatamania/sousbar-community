import Foundation
import Darwin
import SousCore

// sousbar-hook
//
//   --agent <id> Hook mode (what the installed hooks run). The agent pipes its hook JSON
//                into stdin; <id> says which agent it is (claude-code today).
//   (no args)    Hook mode for claude-code, as installed before --agent existed.
//                If SousBar.app isn't running, this exits 0 silently and
//                Claude Code behaves exactly as if the hook didn't exist.
//   install      Add the hooks to ~/.claude/settings.json (backs it up first)
//   uninstall    Remove them again
//   demo [kind]  Send fake events so you can test without Claude Code.
//                kind: flow (default) | permission | always | safe | question | response
//   ping         Check whether the app is listening

signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "install":
    exit(Installer.install())
case "uninstall":
    exit(Installer.uninstall())
case "demo":
    exit(Demo.run(Array(arguments.dropFirst())))
case "ping":
    if let fd = UnixSocket.connect(path: SousPaths.socketPath) {
        close(fd)
        print("SousBar is running.")
        exit(0)
    }
    print("SousBar is not running.")
    exit(1)
default:
    guard let agent = HookMode.agent(from: arguments) else {
        print("Unknown command: \(arguments.joined(separator: " "))")
        exit(0) // never fail a hook
    }
    HookMode.run(agent: agent)
}

enum HookMode {
    /// Environment variables that tell the app which terminal the session lives in.
    static let envKeys = ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "ITERM_SESSION_ID", "__CFBundleIdentifier"]

    static let defaultAgent = "claude-code"

    /// The agent id for hook mode: `--agent <id>`, or claude-code with no arguments.
    /// Returns nil for anything else (not hook mode).
    static func agent(from args: [String]) -> String? {
        if args.isEmpty { return defaultAgent }
        guard args.first == "--agent", args.count >= 2, !args[1].isEmpty else { return nil }
        return args[1]
    }

    static func run(agent client: String) -> Never {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = Wire.decode(stdinData) else { exit(0) }
        let event = input["hook_event_name"] as? String ?? ""
        let reply = send(event: event, input: input, env: currentEnv(), agent: Proc.agentAncestor(), client: client)
        if let output = reply?["output"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    static func currentEnv() -> [String: String] {
        var env: [String: String] = [:]
        let all = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let value = all[key], !value.isEmpty { env[key] = value }
        }
        return env
    }

    /// Sends one event. Only PermissionRequest waits for an answer.
    /// `agent` is the Claude Code process, so the app can drop the session if it dies without
    /// a SessionEnd. Demo events leave it out (their "session" has no real process).
    /// `client` is which agent sent this (e.g. "claude-code").
    static func send(event: String, input: [String: Any], env: [String: String],
                     agent: ProcessIdentity? = nil, client: String = defaultAgent) -> [String: Any]? {
        let blocking = event == "PermissionRequest"
        var message: [String: Any] = [
            "v": 1,
            "event": event,
            "expectsReply": blocking,
            "input": input,
            "env": env,
            "client": client,
        ]
        if let agent { message["agent"] = agent.wire }
        guard let fd = UnixSocket.connect(path: SousPaths.socketPath) else { return nil }
        defer { close(fd) }
        guard let data = Wire.encode(message), UnixSocket.writeAll(fd, data) else { return nil }
        guard blocking else { return nil }
        // Waits as long as the app wants. The app enforces its own timeout,
        // and settings.json gives this hook a hard 600s cap.
        guard let line = UnixSocket.readLine(fd) else { return nil }
        return Wire.decode(line)
    }
}
