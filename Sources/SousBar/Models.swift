import Foundation
import SousCore

enum AgentState: Equatable {
    case idle
    case thinking
    case tool(String)
    case waiting(String)
    case done

    var dot: String {
        switch self {
        case .waiting: return "⚠︎"
        case .thinking, .tool: return "●"
        case .done: return "✓"
        case .idle: return "○"
        }
    }

    var isWorking: Bool {
        switch self {
        case .thinking, .tool: return true
        default: return false
        }
    }
}

enum SessionStatus: Equatable {
    case needsYou    // an approval or question is on the bar
    case inTerminal  // Claude is waiting for you in the terminal itself
    case working
    case newReply
    case idle

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .inTerminal: return "In terminal"
        case .working: return "Working"
        case .newReply: return "New reply"
        case .idle: return "Idle"
        }
    }
}

/// Models and effort levels Claude Code accepts as `/model <alias>` and `/effort <level>`.
enum ModelChoice {
    static let models: [(alias: String, title: String)] = [
        ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable"),
    ]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Does a model id or alias ("claude-opus-5-5", "opus[1m]") belong to `alias`?
    static func matches(_ model: String?, _ alias: String) -> Bool {
        model?.lowercased().contains(alias) ?? false
    }
}

/// Which terminal a session runs in, captured from the hook's environment.
struct TerminalInfo {
    var tmux: String?
    var tmuxPane: String?
    var termProgram: String?
    var itermSessionId: String?
    var bundleId: String?

    init(env: [String: String]) {
        tmux = env["TMUX"]
        tmuxPane = env["TMUX_PANE"]
        termProgram = env["TERM_PROGRAM"]
        itermSessionId = env["ITERM_SESSION_ID"]
        bundleId = env["__CFBundleIdentifier"]
    }

    /// "/private/tmp/tmux-501/default,1234,0" → "/private/tmp/tmux-501/default"
    var tmuxSocket: String? {
        guard let tmux, let first = tmux.split(separator: ",").first else { return nil }
        return String(first)
    }

    /// "w0t1p0:7A1B…" → "7A1B…"
    var itermUUID: String? {
        guard let id = itermSessionId, let colon = id.firstIndex(of: ":") else { return nil }
        return String(id[id.index(after: colon)...])
    }

    var usesTmux: Bool { tmuxPane != nil && tmuxSocket != nil }

    /// Can we type into this session without bringing it to the front?
    var canReceiveText: Bool { usesTmux || itermUUID != nil }
}

final class AgentSession {
    let id: String
    var cwd = ""
    var state: AgentState = .idle
    var lastResponse = ""
    var unread = false
    var terminal = TerminalInfo(env: [:])
    var transcriptPath: String?
    var updated = Date()
    /// The Claude Code process behind this session, when the hook could find it.
    var agent: ProcessIdentity?
    /// From SessionStart, then whatever you pick on the bar (e.g. "claude-opus-5-5" or "opus").
    var model: String?
    var effort: String?
    /// Which agent runs this session ("claude-code"; others later).
    var client = "claude-code"

    /// One status for the session picker and dots.
    func status(hasPending: Bool) -> SessionStatus {
        if hasPending { return .needsYou }
        switch state {
        case .waiting: return .inTerminal
        case .thinking, .tool: return .working
        case .done, .idle: return unread ? .newReply : .idle
        }
    }

    init(id: String) { self.id = id }

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? String(id.prefix(6)) : name
    }
}

/// Holds the answer for a hook that is waiting on the socket.
final class ReplyBox {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    private(set) var output: [String: Any]?

    /// nil output = "no decision", Claude Code shows its normal terminal prompt.
    @discardableResult
    func finish(_ output: [String: Any]?) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        self.output = output
        lock.unlock()
        semaphore.signal()
        return true
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

enum PendingKind {
    /// `suggestions` are Claude Code's own "don't ask again" rules (`permission_suggestions`),
    /// passed back unchanged as `updatedPermissions` when you tap Always.
    case permission(tool: String, summary: String, detail: String, risky: Bool, suggestions: [[String: Any]])
    case question(questions: [[String: Any]], toolInput: [String: Any])
}

/// What a push-to-talk recording is for.
enum VoiceTarget: Equatable {
    /// A new prompt, typed into the session's terminal (tmux / iTerm2 only).
    case prompt(sessionId: String)
    /// The reason for denying this approval, sent back through the hook.
    case denyReason(itemId: UUID)
    /// A free-text answer to one question, sent back through the hook.
    case otherAnswer(itemId: UUID, questionIndex: Int)

    /// The approval or question this recording answers, if any.
    var itemId: UUID? {
        switch self {
        case .prompt: return nil
        case let .denyReason(id), let .otherAnswer(id, _): return id
        }
    }
}

final class PendingItem {
    let id = UUID()
    let sessionId: String
    let kind: PendingKind
    let reply: ReplyBox
    var questionIndex = 0
    var answers: [String: String] = [:]
    var multiSelection: [String] = []

    init(sessionId: String, kind: PendingKind, reply: ReplyBox) {
        self.sessionId = sessionId
        self.kind = kind
        self.reply = reply
    }
}

/// Output formats for the PermissionRequest hook.
enum Decision {
    static func allow(updatedInput: [String: Any]? = nil, updatedPermissions: [[String: Any]]? = nil) -> [String: Any] {
        var decision: [String: Any] = ["behavior": "allow"]
        if let updatedInput { decision["updatedInput"] = updatedInput }
        if let updatedPermissions, !updatedPermissions.isEmpty { decision["updatedPermissions"] = updatedPermissions }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }

    /// What Claude reads when you deny. A spoken reason lets it change course instead of guessing.
    static func denyMessage(reason: String = "") -> String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "The user denied this from the Touch Bar."
                         : "The user denied this from the Touch Bar and said: \(r)"
    }

    /// A spoken "Other" answer, after any options you'd already ticked on a multi-select question.
    static func otherAnswer(selected: [String], spoken: String) -> String {
        let s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        return (selected + (s.isEmpty ? [] : [s])).joined(separator: ", ")
    }

    static func deny(_ message: String) -> [String: Any] {
        ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny", "message": message],
        ]]
    }
}
