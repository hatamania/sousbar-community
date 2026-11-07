import XCTest
import SousCore
@testable import SousBar

/// The bar used to re-read a 2 MB transcript (~200 ms) on every redraw when it had no reply yet.
final class ReplyLookupCostTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "cost-\(UUID().uuidString).jsonl"
        let line = String(data: try! JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user",
            "content": [["type": "tool_result", "tool_use_id": "t", "content": String(repeating: "x", count: 2000)]]]]), encoding: .utf8)!
        FileManager.default.createFile(atPath: path, contents: Data(Array(repeating: line, count: 1000).joined(separator: "\n").utf8))
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    private func session(_ store: Store) -> AgentSession {
        store.handle(["event": "SessionStart", "input": ["session_id": "s", "transcript_path": path!]], reply: nil)
        return store.session("s")!
    }

    private func ms(_ block: () -> Void) -> Double {
        let t0 = Date(); block(); return Date().timeIntervalSince(t0) * 1000
    }

    func testEmptyResultIsRememberedUntilTheFileChanges() throws {
        let store = Store()
        let s = session(store)
        XCTAssertNil(store.replyText(for: s)) // pays the read once
        let repeats = ms { for _ in 0..<50 { XCTAssertNil(store.replyText(for: s)) } }
        XCTAssertLessThan(repeats, 50, "50 lookups should be stat calls, not reads (took \(Int(repeats)) ms)")

        // Claude replies: the file changes, so it's read again and the reply is found.
        Thread.sleep(forTimeInterval: 1.1) // file dates have 1 s resolution on some volumes
        let reply = String(data: try JSONSerialization.data(withJSONObject: ["type": "assistant",
            "message": ["role": "assistant", "content": [["type": "text", "text": "All done."]]]]), encoding: .utf8)!
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        h.seekToEndOfFile(); h.write(Data(("\n" + reply + "\n").utf8)); h.closeFile()
        XCTAssertEqual(store.replyText(for: s), "All done.")
    }

    func testRedrawsNeverReadOnTheMainThread() {
        let store = Store()
        let s = session(store)
        let cost = ms { XCTAssertNil(store.replyTextWithoutWaiting(for: s)) }
        XCTAssertLessThan(cost, 20, "the redraw path returned in \(Int(cost)) ms")
        // and asking again while it loads doesn't start a second read
        XCTAssertNil(store.replyTextWithoutWaiting(for: s))
    }

    func testBackgroundLoadDeliversTheReply() throws {
        let reply = String(data: try JSONSerialization.data(withJSONObject: ["type": "assistant",
            "message": ["role": "assistant", "content": [["type": "text", "text": "Loaded later."]]]]), encoding: .utf8)!
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        h.seekToEndOfFile(); h.write(Data(("\n" + reply + "\n").utf8)); h.closeFile()

        let store = Store()
        let s = session(store)
        let changed = expectation(description: "onChange after the background read")
        store.onChange = { if s.lastResponse == "Loaded later." { changed.fulfill() } }
        XCTAssertNil(store.replyTextWithoutWaiting(for: s))
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(store.replyTextWithoutWaiting(for: s), "Loaded later.")
    }
}

/// A stuck main thread used to leave an approval waiting until the hook's 600 s limit.
final class HookServerDeadlineTests: XCTestCase {
    private var socket: String!
    private var server: HookServer!

    override func setUp() {
        socket = NSTemporaryDirectory() + "as-\(UUID().uuidString.prefix(8)).sock"
        server = HookServer(socketPath: socket)
    }

    override func tearDown() { server.stop() }

    /// Sends a PermissionRequest like the hook does and returns the reply line (off the main thread).
    private func ask(_ done: @escaping ([String: Any]?) -> Void) {
        let path = socket!
        DispatchQueue.global().async {
            guard let fd = UnixSocket.connect(path: path) else { return done(nil) }
            defer { close(fd) }
            let msg: [String: Any] = ["v": 1, "event": "PermissionRequest", "expectsReply": true,
                                      "input": ["session_id": "s", "tool_name": "Bash", "tool_input": [:]], "env": [:]]
            UnixSocket.writeAll(fd, Wire.encode(msg)!)
            done(UnixSocket.readLine(fd).flatMap(Wire.decode))
        }
    }

    func testUnansweredRequestGoesBackToTheTerminal() throws {
        server.replyDeadline = { 0.5 }
        server.onMessage = { _, _ in } // like a stuck main thread: never answers
        let timedOut = expectation(description: "onTimedOut")
        server.onTimedOut = { _ in timedOut.fulfill() }
        try server.start()

        let replied = expectation(description: "hook got a reply")
        var reply: [String: Any]?
        let t0 = Date()
        ask { reply = $0; replied.fulfill() }
        wait(for: [replied, timedOut], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
        XCTAssertTrue(reply?["output"] is NSNull, "no decision: Claude Code shows its own prompt")
    }

    func testAnswerBeforeTheDeadlineStillWins() throws {
        server.replyDeadline = { 5 }
        server.onMessage = { _, box in box?.finish(Decision.allow()) }
        server.onTimedOut = { _ in XCTFail("should not time out") }
        try server.start()

        let replied = expectation(description: "reply")
        var reply: [String: Any]?
        ask { reply = $0; replied.fulfill() }
        wait(for: [replied], timeout: 5)
        let decision = ((reply?["output"] as? [String: Any])?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
    }

    func testDefaultDeadlineFollowsTheSetting() {
        let saved = Settings.approvalTimeout
        defer { Settings.approvalTimeout = saved }
        Settings.approvalTimeout = 60
        XCTAssertEqual(HookServer.defaultDeadline(), 65)
        Settings.approvalTimeout = 0 // "never"
        XCTAssertEqual(HookServer.defaultDeadline(), 590, "just under the hook's 600 s limit")
        Settings.approvalTimeout = 300
        XCTAssertEqual(HookServer.defaultDeadline(), 305)
    }

    func testTimedOutRequestShowsAsWaitingInTerminal() {
        let store = Store()
        let box = ReplyBox()
        store.handle(["event": "PermissionRequest", "input": ["session_id": "s", "tool_name": "Bash", "tool_input": [:]]], reply: box)
        box.finish(nil)
        store.timedOut(box)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.session("s")?.state, .waiting("Waiting for you in the terminal"))
    }
}
