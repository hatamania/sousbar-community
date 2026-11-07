import Foundation
import SousCore

/// All session state. Only touched on the main thread.
final class Store {
    private(set) var sessions: [String: AgentSession] = [:]
    private(set) var pending: [PendingItem] = []

    var onChange: (() -> Void)?
    var onNewPending: ((PendingItem) -> Void)?
    /// A session sent SessionStart (new, resumed or cleared).
    var onSessionStarted: ((AgentSession) -> Void)?

    var sessionsByRecency: [AgentSession] {
        sessions.values.sorted { $0.updated > $1.updated }
    }

    func session(_ id: String) -> AgentSession? { sessions[id] }

    // MARK: - Incoming hook events

    func handle(_ message: [String: Any], reply: ReplyBox?) {
        let event = message["event"] as? String ?? ""
        let input = message["input"] as? [String: Any] ?? [:]
        let env = message["env"] as? [String: String] ?? [:]
        // Every real agent event names its session. Anything else (a malformed or test event) is
        // ignored: it would otherwise show up as a bogus "unknown" session, and because events are
        // matched to sessions by process, it could even push a real session out of the list.
        guard let sid = input["session_id"] as? String, !sid.isEmpty else {
            reply?.finish(nil) // an approval without a session goes to the terminal
            return
        }

        if event == "SessionEnd" {
            removeSession(sid)
            reply?.finish(nil)
            onChange?()
            return
        }

        let session: AgentSession
        if let existing = sessions[sid] {
            session = existing
        } else {
            session = AgentSession(id: sid)
            sessions[sid] = session
        }
        if let cwd = input["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
        if !env.isEmpty { session.terminal = TerminalInfo(env: env) }
        if let path = input["transcript_path"] as? String, !path.isEmpty { session.transcriptPath = path }
        if let agent = ProcessIdentity(wire: message["agent"]) { session.agent = agent }
        if let client = message["client"] as? String, !client.isEmpty { session.client = client }
        // One Claude Code process runs one conversation at a time. After /resume or /clear it reports
        // a new session id, and a session found at launch has a placeholder id until its first event:
        // either way, that process's other entry is out of date.
        if let agent = session.agent {
            for other in sessions.values where other.id != sid && other.agent == agent { removeSession(other.id) }
        }
        session.updated = Date()

        switch event {
        case "SessionStart":
            session.state = .idle
            defer { onSessionStarted?(session) }
            if let model = input["model"] as? String, !model.isEmpty { session.model = model }

        case "UserPromptSubmit":
            session.state = .thinking
            session.unread = false

        case "PreToolUse":
            let tool = input["tool_name"] as? String ?? "Tool"
            let toolInput = input["tool_input"] as? [String: Any] ?? [:]
            session.state = .tool(ToolText.shortLabel(tool, toolInput))

        case "PostToolUse":
            session.state = .thinking

        case "Notification":
            let type = input["notification_type"] as? String ?? ""
            let text = input["message"] as? String ?? ""
            if type == "idle_prompt" {
                if !session.state.isWorking { session.state = .done }
            } else if !pending.contains(where: { $0.sessionId == sid }) {
                session.state = .waiting(text.isEmpty ? "Waiting for you in the terminal" : text)
            }

        case "Stop":
            session.state = .done
            loadResponse(for: session, input: input)

        case "PermissionRequest":
            guard let reply else { break }
            addPending(for: session, input: input, reply: reply)
            return // addPending notifies

        default:
            break
        }
        onChange?()
    }

    private func loadResponse(for session: AgentSession, input: [String: Any]) {
        if let text = input["last_assistant_message"] as? String, !text.isEmpty {
            session.lastResponse = text
            session.unread = true
            return
        }
        guard let path = session.transcriptPath else { return }
        // Give Claude Code a moment to flush the transcript.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let text = Transcript.lastAssistantText(path: path)
            DispatchQueue.main.async {
                guard let self, let text, !text.isEmpty else { return }
                session.lastResponse = text
                session.unread = true
                self.onChange?()
            }
        }
    }

    // MARK: - Approvals & questions

    private func addPending(for session: AgentSession, input: [String: Any], reply: ReplyBox) {
        let tool = input["tool_name"] as? String ?? "Tool"
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]

        let kind: PendingKind
        if tool == "AskUserQuestion",
           let questions = toolInput["questions"] as? [[String: Any]], !questions.isEmpty {
            kind = .question(questions: questions, toolInput: toolInput)
            session.state = .waiting("Claude has a question")
        } else {
            let suggestions = AlwaysRules.usable(input["permission_suggestions"])
            var detail = ToolText.detail(tool, toolInput)
            if let rules = AlwaysRules.describe(suggestions) {
                detail += "\n\n**Always** would allow: \(rules)"
            }
            kind = .permission(
                tool: tool,
                summary: ToolText.summary(tool, toolInput),
                detail: detail,
                risky: !ToolText.readOnly.contains(tool),
                suggestions: suggestions
            )
            session.state = .waiting("Needs approval: \(ToolText.displayName(tool))")
        }

        let item = PendingItem(sessionId: session.id, kind: kind, reply: reply)
        pending.append(item)

        let timeout = Settings.approvalTimeout
        if timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak item] in
                guard let self, let item, self.pending.contains(where: { $0 === item }) else { return }
                self.resolve(item, output: nil)
            }
        }
        onChange?()
        onNewPending?(item)
    }

    /// output == nil hands the decision back to Claude Code's normal terminal prompt.
    func resolve(_ item: PendingItem, output: [String: Any]?) {
        item.reply.finish(output)
        pending.removeAll { $0 === item }
        if let session = sessions[item.sessionId] {
            session.state = output == nil ? .waiting("Waiting for you in the terminal") : .thinking
            session.updated = Date()
        }
        onChange?()
    }

    func cancelled(_ box: ReplyBox) {
        guard let item = pending.first(where: { $0.reply === box }) else { return }
        pending.removeAll { $0 === item }
        if let session = sessions[item.sessionId], case .waiting = session.state {
            session.state = .idle
        }
        onChange?()
    }

    /// The hook server's backstop gave up on this request: it's now in the terminal.
    func timedOut(_ box: ReplyBox) {
        guard let item = pending.first(where: { $0.reply === box }) else { return }
        resolve(item, output: nil) // the box is already finished; this just updates the bar
    }

    func passAllToTerminal() {
        for item in pending { item.reply.finish(nil) }
        pending.removeAll()
    }

    // MARK: - Reply text

    /// Files already read and found to have no reply, by session, until they change.
    private var noReply: [String: (path: String, modified: Date)] = [:]
    /// Conversation files found for sessions that didn't tell us theirs (sessions found running).
    private var foundTranscripts: [String: String] = [:]
    private var loadingReplies: Set<String> = []

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// True if we already know this file has no reply (costs one stat, not a read).
    private func knownEmpty(_ session: AgentSession, _ path: String) -> Bool {
        guard let seen = noReply[session.id], seen.path == path else { return false }
        return Self.modified(path) == seen.modified
    }

    /// The session's last reply, read from its transcript if the app hasn't seen one since it
    /// started. For things you tap (play, the reader panel): reads now if it must, at most once
    /// per change to the file.
    func replyText(for session: AgentSession) -> String? {
        if !session.lastResponse.isEmpty { return session.lastResponse }
        guard let path = transcriptPath(for: session), !knownEmpty(session, path) else { return nil }
        let date = Self.modified(path)
        guard let text = Transcript.lastAssistantText(path: path), !text.isEmpty else {
            if let date { noReply[session.id] = (path, date) }
            return nil
        }
        session.lastResponse = text // not marked unread: it's an old reply
        return text
    }

    /// For redraws: never reads a file on the main thread. Returns what's known and, if nothing is,
    /// loads it in the background and calls onChange when it arrives.
    func replyTextWithoutWaiting(for session: AgentSession) -> String? {
        if !session.lastResponse.isEmpty { return session.lastResponse }
        guard let path = transcriptPath(for: session), !knownEmpty(session, path),
              !loadingReplies.contains(session.id) else { return nil }
        loadingReplies.insert(session.id)
        let id = session.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let date = Self.modified(path)
            let text = Transcript.lastAssistantText(path: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingReplies.remove(id)
                guard let s = self.sessions[id], s.lastResponse.isEmpty else { return }
                if let text, !text.isEmpty {
                    s.lastResponse = text
                    self.onChange?()
                } else if let date {
                    self.noReply[id] = (path, date)
                }
            }
        }
        return nil
    }

    /// The conversation's name, from its transcript (your /rename, Claude's title, or your last prompt).
    func title(for session: AgentSession) -> String? {
        transcriptPath(for: session).flatMap(SessionHistory.title(ofTranscript:))
    }

    /// The hook tells us the transcript; for a session found running, it's the newest
    /// conversation file in its folder written since that Claude Code process started.
    func transcriptPath(for session: AgentSession) -> String? {
        if let p = session.transcriptPath, !p.isEmpty { return p }
        if let found = foundTranscripts[session.id] { return found }
        guard let agent = session.agent else { return nil }
        let dir = SessionHistory.directory(cwd: session.cwd, transcriptPath: nil)
        let started = Date(timeIntervalSince1970: TimeInterval(agent.startSec))
        let fm = FileManager.default
        let newest = (try? fm.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> (String, Date)? in
                let path = dir + "/" + name
                guard let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, d >= started else { return nil }
                return (path, d)
            }
            .max { $0.1 < $1.1 }
        if let path = newest?.0 { foundTranscripts[session.id] = path }
        return newest?.0
    }

    // MARK: - Sessions already running

    /// Placeholder ids for sessions found running before they sent any hook event.
    static func discoveredId(_ agent: ProcessIdentity) -> String { "running-\(agent.pid)-\(agent.startSec)" }

    /// Adds Claude Code processes that are running but haven't sent an event since SousBar
    /// started (e.g. after a reinstall). Their first real event replaces the placeholder.
    @discardableResult
    func adoptRunning(_ agents: [RunningAgent]) -> Int {
        let known = Set(sessions.values.compactMap(\.agent))
        var added = 0
        for a in agents where !known.contains(a.identity) {
            let s = AgentSession(id: Self.discoveredId(a.identity))
            s.cwd = a.cwd
            s.agent = a.identity
            s.terminal = TerminalInfo(env: a.env)
            s.updated = Date(timeIntervalSince1970: TimeInterval(a.identity.startSec))
            sessions[s.id] = s
            added += 1
        }
        if added > 0 { onChange?() }
        return added
    }

    // MARK: - Cleanup

    private func removeSession(_ sid: String) {
        sessions[sid] = nil
        noReply[sid] = nil
        foundTranscripts[sid] = nil
        for item in pending where item.sessionId == sid { item.reply.finish(nil) }
        pending.removeAll { $0.sessionId == sid }
    }

    /// Sessions with no known process (demo, or an older hook) are kept this long after their last event.
    static let unknownProcessTTL: TimeInterval = 12 * 60 * 60

    /// Drops sessions whose Claude Code process is gone (crash, kill -9, closed terminal)
    /// and never sent SessionEnd. Returns how many were removed.
    @discardableResult
    func pruneDead(isAlive: (ProcessIdentity) -> Bool = Proc.isAlive, now: Date = Date()) -> Int {
        let dead = sessions.values.filter { s in
            if let agent = s.agent { return !isAlive(agent) }
            let waiting = pending.contains { $0.sessionId == s.id }
            return !waiting && now.timeIntervalSince(s.updated) > Self.unknownProcessTTL
        }
        guard !dead.isEmpty else { return 0 }
        dead.forEach { removeSession($0.id) }
        onChange?()
        return dead.count
    }

    func markRead(_ session: AgentSession) {
        guard session.unread else { return }
        session.unread = false
        onChange?()
    }
}
