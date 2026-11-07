import AppKit
import XCTest
import SousCore
@testable import SousBar

final class SessionHistoryTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "history-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    @discardableResult
    private func transcript(_ id: String, _ records: [[String: Any]], age: TimeInterval = 0) -> String {
        let path = "\(dir!)/\(id).jsonl"
        let text = records.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                       attributes: [.modificationDate: Date().addingTimeInterval(-age)])
        return path
    }

    private func prompt(_ text: Any) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text]]
    }

    func testEncodeMatchesClaudeCode() {
        XCTAssertEqual(SessionHistory.encode("/Users/me/source/sousbar"), "-Users-me-source-sousbar")
        XCTAssertEqual(SessionHistory.encode("/a/my.app_v2 x"), "-a-my-app-v2-x")
    }

    func testDirectoryPrefersTranscriptLocation() {
        XCTAssertEqual(SessionHistory.directory(cwd: "/x", transcriptPath: "/p/-x/abc.jsonl"), "/p/-x")
        XCTAssertEqual(SessionHistory.directory(cwd: "/x/y", transcriptPath: nil), SessionHistory.projectsRoot + "/-x-y")
    }

    func testTitlePriority() {
        let all = transcript("a", [prompt("first"), ["type": "last-prompt", "lastPrompt": "latest prompt"],
                                   ["type": "ai-title", "aiTitle": "AI title"], ["type": "custom-title", "customTitle": "My name"]])
        XCTAssertEqual(SessionHistory.title(ofTranscript: all), "My name")
        let ai = transcript("b", [prompt("first"), ["type": "ai-title", "aiTitle": "AI title"],
                                  ["type": "last-prompt", "lastPrompt": "latest"]])
        XCTAssertEqual(SessionHistory.title(ofTranscript: ai), "AI title")
        let last = transcript("c", [prompt("first"), ["type": "last-prompt", "lastPrompt": "fix\n  the   build"]])
        XCTAssertEqual(SessionHistory.title(ofTranscript: last), "fix the build")
        let first = transcript("d", [prompt([["type": "text", "text": "hello there"]])])
        XCTAssertEqual(SessionHistory.title(ofTranscript: first), "hello there")
    }

    func testLatestTitleWins() {
        let p = transcript("a", [["type": "ai-title", "aiTitle": "Old"], ["type": "ai-title", "aiTitle": "New"]])
        XCTAssertEqual(SessionHistory.title(ofTranscript: p), "New")
    }

    func testCommandNoiseIsNotATitle() {
        let p = transcript("a", [prompt("<command-name>/clear</command-name>"), prompt("real question")])
        XCTAssertEqual(SessionHistory.title(ofTranscript: p), "real question")
        XCTAssertNil(SessionHistory.tidy("  <local-command-stdout>x</local-command-stdout>"))
    }

    func testListIsNewestFirstAndSkipsEmptyAndSubfolders() throws {
        transcript("old", [prompt("old one")], age: 7200)
        transcript("new", [prompt("new one")], age: 10)
        transcript("empty", [["type": "mode", "mode": "normal"]], age: 5)
        try FileManager.default.createDirectory(atPath: dir + "/new", withIntermediateDirectories: true) // subagent folder
        FileManager.default.createFile(atPath: dir + "/notes.txt", contents: Data())
        let list = SessionHistory.list(in: dir)
        XCTAssertEqual(list.map(\.id), ["new", "old"])
        XCTAssertEqual(list.map(\.title), ["new one", "old one"])
    }

    func testMissingDirectory() {
        XCTAssertEqual(SessionHistory.list(in: dir + "/nope"), [])
    }

    func testRelative() {
        let now = Date()
        XCTAssertEqual(SessionHistory.relative(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(SessionHistory.relative(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(SessionHistory.relative(now.addingTimeInterval(-3 * 3600), now: now), "3h ago")
        XCTAssertEqual(SessionHistory.relative(now.addingTimeInterval(-2 * 86400), now: now), "2d ago")
        XCTAssertFalse(SessionHistory.relative(now.addingTimeInterval(-30 * 86400), now: now).hasSuffix("ago"))
    }
}

final class SessionPickerTests: XCTestCase {
    private func live(_ id: String, _ cwd: String, _ state: AgentState = .idle) -> AgentSession {
        let s = AgentSession(id: id)
        s.cwd = cwd
        s.state = state
        return s
    }

    func testHistoryIsOnlyThisFolder() {
        let now = Date()
        let here = live("L1", "/p/app", .thinking)
        let other = live("X1", "/p/web")
        let history = [PastSession(id: "L1", title: "Fix login", updated: now),
                       PastSession(id: "H1", title: "Add tests", updated: now.addingTimeInterval(-3600)),
                       PastSession(id: "H2", title: "Old idea", updated: now.addingTimeInterval(-86400 * 3))]
        let entries = SessionPicker.entries(folder: "/p/app", live: [other, here],
                                            status: { $0.status(hasPending: false) }, history: history, now: now)
        XCTAssertEqual(entries.map(\.id), ["L1", "H1", "H2"], "no sessions from other folders")
        XCTAssertEqual(entries[0], PickerEntry(id: "L1", title: "Fix login", subtitle: "Working", kind: .live(.working)))
        XCTAssertEqual(entries[1].kind, .past)
        XCTAssertEqual(entries[1].subtitle, "1h ago")
    }

    func testLiveSessionTitleFallsBackToTranscriptThenNewSession() {
        let a = live("a", "/p/app"), b = live("b", "/p/app")
        let entries = SessionPicker.entries(folder: "/p/app", live: [a, b], status: { $0.status(hasPending: false) },
                                            title: { $0.id == "a" ? "From transcript" : nil }, history: [])
        XCTAssertEqual(entries.map(\.title), ["From transcript", "New session"])
    }

    func testChipListShowsNameFolderAndStatusForEveryFolder() {
        let a = live("a", "/p/app", .thinking), b = live("b", "/p/web")
        b.unread = true
        let entries = SessionPicker.active(live: [a, b], status: { $0.status(hasPending: false) },
                                           title: { $0.id == "a" ? "Fix login" : nil })
        XCTAssertEqual(entries, [
            PickerEntry(id: "a", title: "Fix login", subtitle: "app · Working", kind: .live(.working)),
            PickerEntry(id: "b", title: "New session", subtitle: "web · New reply", kind: .live(.newReply)),
        ])
    }
}

final class ResumeDedupeTests: XCTestCase {
    func testNewSessionIdInSameProcessReplacesOldEntry() {
        let store = Store()
        let agent = ProcessIdentity(pid: 77, startSec: 1, startUsec: 2)
        let box = ReplyBox()
        store.handle(["event": "SessionStart", "input": ["session_id": "old", "cwd": "/p"], "agent": agent.wire], reply: nil)
        store.handle(["event": "PermissionRequest", "input": ["session_id": "old", "tool_name": "Bash", "tool_input": [:]],
                      "agent": agent.wire], reply: box)
        store.handle(["event": "SessionStart", "input": ["session_id": "resumed", "cwd": "/p", "source": "resume"],
                      "agent": agent.wire], reply: nil)
        XCTAssertNil(store.session("old"))
        XCTAssertNotNil(store.session("resumed"))
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(box.wait(timeout: 0))
    }

    func testDifferentProcessesKeepTheirSessions() {
        let store = Store()
        store.handle(["event": "SessionStart", "input": ["session_id": "a"],
                      "agent": ProcessIdentity(pid: 1, startSec: 1, startUsec: 1).wire], reply: nil)
        store.handle(["event": "SessionStart", "input": ["session_id": "b"],
                      "agent": ProcessIdentity(pid: 2, startSec: 1, startUsec: 1).wire], reply: nil)
        XCTAssertEqual(store.sessions.count, 2)
    }
}

final class AdoptRunningTests: XCTestCase {
    private let agent = ProcessIdentity(pid: 4242, startSec: 1_790_000_000, startUsec: 5)

    private func running(_ id: ProcessIdentity, _ cwd: String = "/Users/me/web") -> RunningAgent {
        RunningAgent(identity: id, cwd: cwd, env: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w1t1p0:ABC"])
    }

    func testAdoptsUnknownRunningSession() {
        let store = Store()
        var changes = 0
        store.onChange = { changes += 1 }
        XCTAssertEqual(store.adoptRunning([running(agent)]), 1)
        let s = store.session(Store.discoveredId(agent))
        XCTAssertEqual(s?.project, "web")
        XCTAssertEqual(s?.state, .idle)
        XCTAssertEqual(s?.terminal.itermUUID, "ABC", "voice and model picker can reach it right away")
        XCTAssertEqual(changes, 1)
    }

    func testDoesNotDuplicateKnownProcessOrReAdd() {
        let store = Store()
        store.handle(["event": "UserPromptSubmit", "input": ["session_id": "real", "cwd": "/p"], "agent": agent.wire], reply: nil)
        XCTAssertEqual(store.adoptRunning([running(agent)]), 0)
        XCTAssertEqual(store.sessions.count, 1)
        let other = ProcessIdentity(pid: 9, startSec: 1, startUsec: 1)
        XCTAssertEqual(store.adoptRunning([running(other)]), 1)
        XCTAssertEqual(store.adoptRunning([running(other)]), 0)
    }

    func testFirstRealEventReplacesPlaceholder() {
        let store = Store()
        store.adoptRunning([running(agent)])
        store.handle(["event": "PreToolUse", "input": ["session_id": "real-id", "cwd": "/Users/me/web",
                                                       "tool_name": "Read", "tool_input": [:]], "agent": agent.wire], reply: nil)
        XCTAssertNil(store.session(Store.discoveredId(agent)))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.session("real-id")?.state, .tool("Read"))
    }

    func testActivePickerListsEveryLiveSession() {
        let a = AgentSession(id: "a"); a.cwd = "/x/one"
        let b = AgentSession(id: "b"); b.cwd = "/x/two"; b.state = .thinking
        let entries = SessionPicker.active(live: [b, a], status: { $0.status(hasPending: false) }, title: { _ in nil })
        XCTAssertEqual(entries.map(\.subtitle), ["two · Working", "one · Idle"])
    }

    func testLongFolderNeverHidesTheStatus() {
        let out = SessionPicker.folderAndStatus("sousbar-touchbar-polish", "Working", width: 138)
        XCTAssertTrue(out.hasSuffix(" · Working"), out)
        XCTAssertTrue(out.hasPrefix("sousbar"), out)
        XCTAssertLessThanOrEqual(ceil((out as NSString).size(withAttributes: [.font: SessionPicker.subtitleFont]).width), 138)
        XCTAssertEqual(SessionPicker.folderAndStatus("web", "Idle", width: 138), "web · Idle")
    }

    func testStoreTitleComesFromTranscript() throws {
        let path = NSTemporaryDirectory() + "title-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let line = String(data: try JSONSerialization.data(withJSONObject: ["type": "ai-title", "aiTitle": "Polish UI"]), encoding: .utf8)!
        FileManager.default.createFile(atPath: path, contents: Data((line + "\n").utf8))
        let store = Store()
        store.handle(["event": "UserPromptSubmit", "input": ["session_id": "s", "transcript_path": path]], reply: nil)
        XCTAssertEqual(store.title(for: store.session("s")!), "Polish UI")
    }
}
