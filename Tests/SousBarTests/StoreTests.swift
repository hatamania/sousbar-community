import XCTest
import SousCore
@testable import SousBar

final class StoreTests: XCTestCase {
    private var store: Store!
    private var changes = 0
    private var newPending: [PendingItem] = []

    override func setUp() {
        store = Store()
        changes = 0
        newPending = []
        store.onChange = { [unowned self] in changes += 1 }
        store.onNewPending = { [unowned self] in newPending.append($0) }
    }

    private func send(_ event: String, sid: String = "s1", reply: ReplyBox? = nil,
                      env: [String: String] = [:], _ extra: [String: Any] = [:]) {
        var input: [String: Any] = ["hook_event_name": event, "session_id": sid, "cwd": "/Users/me/proj-\(sid)"]
        for (k, v) in extra { input[k] = v }
        store.handle(["event": event, "input": input, "env": env], reply: reply)
    }

    // MARK: Lifecycle

    func testSessionStartCreatesIdleSession() {
        send("SessionStart", env: ["TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%3"])
        let s = store.session("s1")
        XCTAssertEqual(s?.state, .idle)
        XCTAssertEqual(s?.project, "proj-s1")
        XCTAssertEqual(s?.terminal.tmuxPane, "%3")
        XCTAssertEqual(changes, 1)
    }

    func testPromptThenToolThenStop() {
        send("SessionStart")
        send("UserPromptSubmit")
        XCTAssertEqual(store.session("s1")?.state, .thinking)

        send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make"]])
        XCTAssertEqual(store.session("s1")?.state, .tool("Bash: make"))

        send("PostToolUse", ["tool_name": "Bash"])
        XCTAssertEqual(store.session("s1")?.state, .thinking)

        send("Stop", ["last_assistant_message": "All done."])
        let s = store.session("s1")
        XCTAssertEqual(s?.state, .done)
        XCTAssertEqual(s?.lastResponse, "All done.")
        XCTAssertEqual(s?.unread, true)
    }

    func testNewPromptClearsUnread() {
        send("Stop", ["last_assistant_message": "x"])
        send("UserPromptSubmit")
        XCTAssertEqual(store.session("s1")?.unread, false)
    }

    func testSessionEndRemovesSessionAndReleasesPending() {
        let box = ReplyBox()
        send("PermissionRequest", reply: box, ["tool_name": "Bash", "tool_input": ["command": "rm x"]])
        XCTAssertEqual(store.pending.count, 1)

        send("SessionEnd")
        XCTAssertNil(store.session("s1"))
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(box.wait(timeout: 0))
        XCTAssertNil(box.output, "ending the session hands the decision back to the terminal")
    }

    func testSessionEndOnlyAffectsThatSession() {
        let other = ReplyBox()
        send("PermissionRequest", sid: "s2", reply: other, ["tool_name": "Bash", "tool_input": [:]])
        send("SessionEnd", sid: "s1")
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertFalse(other.wait(timeout: 0))
    }

    func testSessionsByRecency() {
        send("SessionStart", sid: "a")
        send("SessionStart", sid: "b")
        send("UserPromptSubmit", sid: "a")
        XCTAssertEqual(store.sessionsByRecency.map(\.id), ["a", "b"])
    }

    // MARK: Notifications

    func testIdlePromptMarksDoneOnlyWhenNotWorking() {
        send("UserPromptSubmit")
        send("Notification", ["notification_type": "idle_prompt"])
        XCTAssertEqual(store.session("s1")?.state, .thinking)

        send("Stop", ["last_assistant_message": "x"])
        send("Notification", ["notification_type": "idle_prompt"])
        XCTAssertEqual(store.session("s1")?.state, .done)
    }

    func testOtherNotificationShowsWaiting() {
        send("Notification", ["notification_type": "permission_prompt", "message": "Claude needs permission"])
        XCTAssertEqual(store.session("s1")?.state, .waiting("Claude needs permission"))
    }

    func testNotificationDoesNotOverrideTouchBarPending() {
        send("PermissionRequest", reply: ReplyBox(), ["tool_name": "Bash", "tool_input": [:]])
        send("Notification", ["notification_type": "permission_prompt", "message": "other"])
        XCTAssertEqual(store.session("s1")?.state, .waiting("Needs approval: Bash"))
    }

    // MARK: Approvals

    func testRiskyPermission() {
        send("PermissionRequest", reply: ReplyBox(), ["tool_name": "Bash", "tool_input": ["command": "rm -rf dist"]])
        XCTAssertEqual(newPending.count, 1)
        guard case let .permission(tool, summary, _, risky, _) = store.pending.first?.kind else {
            return XCTFail("expected a permission")
        }
        XCTAssertEqual(tool, "Bash")
        XCTAssertEqual(summary, "rm -rf dist")
        XCTAssertTrue(risky)
    }

    func testReadOnlyPermissionIsNotRisky() {
        send("PermissionRequest", reply: ReplyBox(), ["tool_name": "Read", "tool_input": ["file_path": "/a/b"]])
        guard case let .permission(_, _, _, risky, _) = store.pending.first?.kind else { return XCTFail() }
        XCTAssertFalse(risky)
    }

    func testPermissionSuggestionsAreKeptAndDescribed() {
        let suggestion: [String: Any] = [
            "type": "addRules", "behavior": "allow", "destination": "localSettings",
            "rules": [["toolName": "Bash", "ruleContent": "npm run build:*"]],
        ]
        send("PermissionRequest", reply: ReplyBox(), [
            "tool_name": "Bash", "tool_input": ["command": "npm run build"],
            "permission_suggestions": [suggestion, "junk"],
        ])
        guard case let .permission(_, _, detail, _, suggestions) = store.pending.first?.kind else { return XCTFail() }
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?["type"] as? String, "addRules")
        XCTAssertTrue(detail.hasSuffix("**Always** would allow: Bash(npm run build:*) in this project"), detail)
    }

    func testNoSuggestionsMeansNoAlways() {
        send("PermissionRequest", reply: ReplyBox(), ["tool_name": "Bash", "tool_input": ["command": "ls"]])
        guard case let .permission(_, _, detail, _, suggestions) = store.pending.first?.kind else { return XCTFail() }
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertFalse(detail.contains("Always"))
    }

    func testAlwaysSendsSuggestionsBackUnchanged() throws {
        let suggestion: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        let box = ReplyBox()
        send("PermissionRequest", reply: box, [
            "tool_name": "Edit", "tool_input": ["file_path": "/a/b.swift"], "permission_suggestions": [suggestion],
        ])
        let item = try XCTUnwrap(store.pending.first)
        guard case let .permission(_, _, _, _, suggestions) = item.kind else { return XCTFail() }
        store.resolve(item, output: Decision.allow(updatedPermissions: suggestions))

        let decision = (box.output?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        let sent = try XCTUnwrap(decision?["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(NSDictionary(dictionary: sent[0]).isEqual(to: suggestion))
    }

    func testPermissionWithoutReplyBoxIsIgnored() {
        send("PermissionRequest", ["tool_name": "Bash", "tool_input": [:]])
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testAskUserQuestionBecomesQuestion() {
        let questions: [[String: Any]] = [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]
        send("PermissionRequest", reply: ReplyBox(), ["tool_name": "AskUserQuestion", "tool_input": ["questions": questions]])
        guard case let .question(qs, _) = store.pending.first?.kind else { return XCTFail("expected a question") }
        XCTAssertEqual(qs.count, 1)
        XCTAssertEqual(store.session("s1")?.state, .waiting("Claude has a question"))
    }

    func testAskUserQuestionWithoutQuestionsFallsBackToPermission() {
        send("PermissionRequest", reply: ReplyBox(), ["tool_name": "AskUserQuestion", "tool_input": [:]])
        guard case .permission = store.pending.first?.kind else { return XCTFail() }
    }

    func testResolveAllowSendsDecisionAndResumes() throws {
        let box = ReplyBox()
        send("PermissionRequest", reply: box, ["tool_name": "Bash", "tool_input": [:]])
        let item = try XCTUnwrap(store.pending.first)
        store.resolve(item, output: Decision.allow())

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(box.wait(timeout: 0))
        let decision = (box.output?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertEqual(store.session("s1")?.state, .thinking)
    }

    func testResolveToTerminal() throws {
        let box = ReplyBox()
        send("PermissionRequest", reply: box, ["tool_name": "Bash", "tool_input": [:]])
        store.resolve(try XCTUnwrap(store.pending.first), output: nil)
        XCTAssertTrue(box.wait(timeout: 0))
        XCTAssertNil(box.output)
        XCTAssertEqual(store.session("s1")?.state, .waiting("Waiting for you in the terminal"))
    }

    func testCancelledHookRemovesPending() {
        let box = ReplyBox()
        send("PermissionRequest", reply: box, ["tool_name": "Bash", "tool_input": [:]])
        store.cancelled(box)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.session("s1")?.state, .idle)
    }

    func testPassAllToTerminal() {
        let a = ReplyBox(), b = ReplyBox()
        send("PermissionRequest", sid: "a", reply: a, ["tool_name": "Bash", "tool_input": [:]])
        send("PermissionRequest", sid: "b", reply: b, ["tool_name": "Edit", "tool_input": [:]])
        store.passAllToTerminal()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(a.wait(timeout: 0))
        XCTAssertTrue(b.wait(timeout: 0))
    }
}

final class DecisionTests: XCTestCase {
    func testAllowWithUpdatedInput() {
        let out = Decision.allow(updatedInput: ["answers": ["Q": "A"]])
        let specific = out["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(specific?["hookEventName"] as? String, "PermissionRequest")
        let decision = specific?["decision"] as? [String: Any]
        XCTAssertEqual((decision?["updatedInput"] as? [String: Any])?["answers"] as? [String: String], ["Q": "A"])
    }

    func testPlainAllowHasNoUpdatedPermissions() {
        let decision = (Decision.allow(updatedPermissions: [])["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertNil(decision?["updatedPermissions"])
        XCTAssertNil(decision?["updatedInput"])
    }

    func testDeny() {
        let decision = (Decision.deny("no")["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertEqual(decision?["message"] as? String, "no")
    }
}

final class ReplyBoxTests: XCTestCase {
    func testFinishesOnlyOnce() {
        let box = ReplyBox()
        XCTAssertFalse(box.wait(timeout: 0))
        XCTAssertTrue(box.finish(["a": 1]))
        XCTAssertFalse(box.finish(["b": 2]))
        XCTAssertTrue(box.wait(timeout: 0))
        XCTAssertEqual(box.output?["a"] as? Int, 1)
    }
}

final class TerminalInfoTests: XCTestCase {
    func testTmux() {
        let t = TerminalInfo(env: ["TMUX": "/private/tmp/tmux-501/default,1234,0", "TMUX_PANE": "%7"])
        XCTAssertEqual(t.tmuxSocket, "/private/tmp/tmux-501/default")
        XCTAssertTrue(t.usesTmux)
        XCTAssertTrue(t.canReceiveText)
    }

    func testITerm() {
        let t = TerminalInfo(env: ["ITERM_SESSION_ID": "w0t1p0:7A1B-22"])
        XCTAssertEqual(t.itermUUID, "7A1B-22")
        XCTAssertFalse(t.usesTmux)
        XCTAssertTrue(t.canReceiveText)
    }

    func testPlainTerminalCannotReceiveText() {
        let t = TerminalInfo(env: ["TERM_PROGRAM": "Apple_Terminal"])
        XCTAssertFalse(t.canReceiveText)
    }

    func testProjectFallsBackToSessionIdPrefix() {
        XCTAssertEqual(AgentSession(id: "abcdef123").project, "abcdef")
    }
}

final class PruneTests: XCTestCase {
    private let alive = ProcessIdentity(pid: 100, startSec: 1, startUsec: 0)
    private let dead = ProcessIdentity(pid: 200, startSec: 1, startUsec: 0)

    private func event(_ store: Store, _ name: String, sid: String, agent: ProcessIdentity?,
                       reply: ReplyBox? = nil, _ extra: [String: Any] = [:]) {
        var input: [String: Any] = ["session_id": sid, "cwd": "/p/\(sid)"]
        for (k, v) in extra { input[k] = v }
        var message: [String: Any] = ["event": name, "input": input]
        if let agent { message["agent"] = agent.wire }
        store.handle(message, reply: reply)
    }

    private func isAlive(_ id: ProcessIdentity) -> Bool { id == alive }

    func testAgentIsRecordedFromMessage() {
        let store = Store()
        event(store, "SessionStart", sid: "a", agent: alive)
        XCTAssertEqual(store.session("a")?.agent, alive)
        event(store, "UserPromptSubmit", sid: "a", agent: nil)
        XCTAssertEqual(store.session("a")?.agent, alive, "an event without agent info keeps the old one")
    }

    func testDeadProcessSessionIsRemovedAndItsApprovalReleased() {
        let store = Store()
        var changes = 0
        store.onChange = { changes += 1 }
        let box = ReplyBox()
        event(store, "SessionStart", sid: "live", agent: alive)
        event(store, "PermissionRequest", sid: "gone", agent: dead, reply: box, ["tool_name": "Bash", "tool_input": [:]])
        changes = 0

        XCTAssertEqual(store.pruneDead(isAlive: isAlive), 1)
        XCTAssertNil(store.session("gone"))
        XCTAssertNotNil(store.session("live"))
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(box.wait(timeout: 0))
        XCTAssertNil(box.output)
        XCTAssertEqual(changes, 1)
    }

    func testNothingToPruneDoesNotNotify() {
        let store = Store()
        event(store, "SessionStart", sid: "live", agent: alive)
        var changes = 0
        store.onChange = { changes += 1 }
        XCTAssertEqual(store.pruneDead(isAlive: isAlive), 0)
        XCTAssertEqual(changes, 0)
    }

    func testSessionWithoutProcessExpiresAfterTTL() {
        let store = Store()
        event(store, "SessionStart", sid: "demo", agent: nil)
        let soon = Date().addingTimeInterval(Store.unknownProcessTTL - 60)
        let later = Date().addingTimeInterval(Store.unknownProcessTTL + 60)
        XCTAssertEqual(store.pruneDead(isAlive: isAlive, now: soon), 0)
        XCTAssertEqual(store.pruneDead(isAlive: isAlive, now: later), 1)
    }

    func testSessionWithoutProcessIsKeptWhileWaitingForAnswer() {
        let store = Store()
        event(store, "PermissionRequest", sid: "demo", agent: nil, reply: ReplyBox(), ["tool_name": "Bash", "tool_input": [:]])
        let later = Date().addingTimeInterval(Store.unknownProcessTTL * 2)
        XCTAssertEqual(store.pruneDead(isAlive: isAlive, now: later), 0)
    }
}

final class MissingSessionIdTests: XCTestCase {
    /// Seen while testing the release build: an event with no session_id became an "unknown"
    /// session and, through process matching, replaced the real session of that process.
    func testEventWithoutSessionIsIgnored() {
        let store = Store()
        let agent = ProcessIdentity(pid: 5, startSec: 1, startUsec: 1)
        store.handle(["event": "SessionStart", "input": ["session_id": "real"], "agent": agent.wire], reply: nil)
        var changes = 0
        store.onChange = { changes += 1 }
        store.handle(["event": "Notification", "input": ["notification_type": "x"], "agent": agent.wire], reply: nil)
        store.handle(["event": "Stop", "input": ["session_id": ""], "agent": agent.wire], reply: nil)
        XCTAssertEqual(store.sessions.keys.sorted(), ["real"], "the real session survives")
        XCTAssertEqual(changes, 0)
    }

    func testApprovalWithoutSessionGoesToTheTerminal() {
        let store = Store()
        let box = ReplyBox()
        store.handle(["event": "PermissionRequest", "input": ["tool_name": "Bash", "tool_input": [:]]], reply: box)
        XCTAssertTrue(box.wait(timeout: 0), "answered at once, so Claude Code isn't left waiting")
        XCTAssertNil(box.output)
        XCTAssertTrue(store.pending.isEmpty)
    }
}
