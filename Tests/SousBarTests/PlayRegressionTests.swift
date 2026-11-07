import AppKit
import XCTest
import SousCore
@testable import SousBar

/// Regressions for "the play button doesn't work".
final class PlayRegressionTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Touch Bar views may have no window; the reader used to wait for one and never advanced.
    func testReaderAdvancesWithoutAWindow() {
        let host = NSView()
        let v = SpeedReaderView(text: "one two three four five six seven eight", wpm: 700)
        host.addSubview(v)
        XCTAssertNil(v.window)
        v.play()
        spin(0.8)
        XCTAssertGreaterThan(v.engine.index, 0)
    }

    func testReaderStopsWhenTakenOffTheBar() {
        let host = NSView()
        let v = SpeedReaderView(text: Array(repeating: "word", count: 50).joined(separator: " "), wpm: 700)
        host.addSubview(v)
        v.play()
        spin(0.3)
        v.removeFromSuperview()
        let stoppedAt = v.engine.index
        spin(0.4)
        XCTAssertEqual(v.engine.index, stoppedAt)
    }

    func testWorkingAnimationRunsWithoutAWindow() {
        let host = NSView()
        let p = PagedTextView()
        host.addSubview(p)
        p.setActivity(nil)
        let before = p.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        spin(0.5)
        let after = p.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertNotEqual(before, after, "the spinner glyph moves")
    }
}

final class ReplyTextTests: XCTestCase {
    private var dir: String!
    override func setUp() {
        dir = NSTemporaryDirectory() + "reply-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func writeTranscript(_ path: String, reply: String) {
        let lines = [
            ["type": "user", "message": ["role": "user", "content": "hi"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": reply]]]],
        ].map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        FileManager.default.createFile(atPath: path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    func testReplyComesFromTranscriptAfterRestart() {
        let path = dir + "/s.jsonl"
        writeTranscript(path, reply: "Fixed the build.")
        let store = Store()
        store.handle(["event": "UserPromptSubmit", "input": ["session_id": "s", "transcript_path": path]], reply: nil)
        let s = store.session("s")!
        s.state = .done
        XCTAssertEqual(store.replyText(for: s), "Fixed the build.")
        XCTAssertFalse(s.unread, "an old reply isn't new")
    }

    func testSessionFoundRunningUsesNewestTranscriptSinceItStarted() throws {
        let fm = FileManager.default
        let cwd = "/tmp/sousbar-test-\(UUID().uuidString)"
        let historyDir = SessionHistory.directory(cwd: cwd, transcriptPath: nil)
        try fm.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: historyDir) }
        let started = Date().addingTimeInterval(-600)
        writeTranscript(historyDir + "/old.jsonl", reply: "old")
        try fm.setAttributes([.modificationDate: started.addingTimeInterval(-60)], ofItemAtPath: historyDir + "/old.jsonl")
        writeTranscript(historyDir + "/new.jsonl", reply: "current conversation")

        let store = Store()
        store.adoptRunning([RunningAgent(identity: ProcessIdentity(pid: 7, startSec: Int(started.timeIntervalSince1970), startUsec: 0),
                                         cwd: cwd, env: [:])])
        let s = try XCTUnwrap(store.sessions.values.first)
        XCTAssertEqual(store.replyText(for: s), "current conversation")
    }

    func testNoTranscriptNoReply() {
        let store = Store()
        store.handle(["event": "SessionStart", "input": ["session_id": "s"]], reply: nil)
        XCTAssertNil(store.replyText(for: store.session("s")!))
    }
}
