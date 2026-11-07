import XCTest
@testable import SousBar

final class TranscriptTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "sousbar-transcript-\(UUID().uuidString).jsonl"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func write(_ entries: [[String: Any]]) {
        let lines = entries.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        FileManager.default.createFile(atPath: path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func user(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text]]
    }

    private func toolResult() -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]]
    }

    private func assistant(_ text: String, sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain,
         "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    private func toolUseOnly() -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]]]]
    }

    func testMissingFile() {
        XCTAssertNil(Transcript.lastAssistantText(path: path))
    }

    func testOnlyTheLastTurnIsReturned() {
        write([
            user("first prompt"), assistant("old answer"),
            user("second prompt"), assistant("Looking."), toolUseOnly(), toolResult(), assistant("Fixed it."),
        ])
        XCTAssertEqual(Transcript.lastAssistantText(path: path), "Looking.\n\nFixed it.")
    }

    func testSidechainMessagesAreSkipped() {
        write([user("go"), assistant("subagent chatter", sidechain: true), assistant("Main answer")])
        XCTAssertEqual(Transcript.lastAssistantText(path: path), "Main answer")
    }

    func testPromptWithTextBlocksEndsTheTurn() {
        write([
            user("old"), assistant("old answer"),
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "new prompt"]]]],
            assistant("new answer"),
        ])
        XCTAssertEqual(Transcript.lastAssistantText(path: path), "new answer")
    }

    func testTurnWithNoTextReturnsNil() {
        write([user("go"), toolUseOnly(), toolResult()])
        XCTAssertNil(Transcript.lastAssistantText(path: path))
    }

    func testIgnoresMalformedLines() {
        FileManager.default.createFile(atPath: path, contents: Data("not json\n".utf8))
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(try! JSONSerialization.data(withJSONObject: assistant("still found")))
        handle.closeFile()
        XCTAssertEqual(Transcript.lastAssistantText(path: path), "still found")
    }
}
