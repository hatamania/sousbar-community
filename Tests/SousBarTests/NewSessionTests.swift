import AppKit
import XCTest
@testable import SousBar

final class NewSessionPlanTests: XCTestCase {
    func testPlanFollowsTheNearbyTerminal() {
        XCTAssertEqual(TerminalBridge.plan(for: TerminalInfo(env: ["TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%1",
                                                                    "TERM_PROGRAM": "iTerm.app"])),
                       .tmux(socket: "/tmp/tmux-501/default"), "tmux wins: works inside any terminal")
        XCTAssertEqual(TerminalBridge.plan(for: TerminalInfo(env: ["ITERM_SESSION_ID": "w0t1p0:ABC", "TERM_PROGRAM": "iTerm.app"])),
                       .iterm(nearSession: "ABC"))
        XCTAssertEqual(TerminalBridge.plan(for: TerminalInfo(env: ["TERM_PROGRAM": "iTerm.app"])), .iterm(nearSession: nil))
        XCTAssertEqual(TerminalBridge.plan(for: TerminalInfo(env: ["TERM_PROGRAM": "Apple_Terminal"])), .terminalApp)
        XCTAssertEqual(TerminalBridge.plan(for: nil), .terminalApp)
    }

    func testStartCommandQuotesTheFolder() {
        XCTAssertEqual(TerminalBridge.startCommand(in: "/Users/me/my app"), "cd '/Users/me/my app' && claude")
        XCTAssertEqual(TerminalBridge.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(TerminalBridge.shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'", "no expansion inside single quotes")
    }

    func testMissingFolderIsRefusedBeforeOpeningAnything() {
        XCTAssertEqual(TerminalBridge.newSession(in: "/nonexistent/\(UUID().uuidString)", like: nil),
                       "That folder doesn't exist any more")
    }
}

final class NewSessionFlowTests: XCTestCase {
    private var store: Store!
    private var bar: TouchBarController!
    private var opened: [(String, TerminalInfo?)] = []

    override func setUp() {
        store = Store()
        bar = TouchBarController(store: store)
        opened = []
        bar.openNewSession = { [unowned self] folder, terminal in opened.append((folder, terminal)); return nil }
        store.handle(["event": "SessionStart", "input": ["session_id": "old", "cwd": "/Users/me/app"],
                      "env": ["ITERM_SESSION_ID": "w0t0p0:NEAR", "TERM_PROGRAM": "iTerm.app"]], reply: nil)
    }

    func testNewButtonIsInTheFolderList() throws {
        bar.openSessions()
        let new = try XCTUnwrap(bar.itemViews.compactMap { $0 as? HoldButton }.first { $0.title == "New" })
        new.onComplete?()
        XCTAssertEqual(opened.map(\.0), ["/Users/me/app"])
        XCTAssertEqual(opened.first?.1?.itermUUID, "NEAR", "opens next to this folder's session")
        XCTAssertEqual(bar.mode, .normal)
    }

    func testSwitchesToTheNewSessionWhenItStarts() {
        bar.openSessions()
        bar.newSession()
        store.handle(["event": "SessionStart", "input": ["session_id": "elsewhere", "cwd": "/Users/me/other"]], reply: nil)
        XCTAssertNotEqual(bar.currentSessionId, "elsewhere", "a session in another folder isn't the one we opened")
        store.handle(["event": "SessionStart", "input": ["session_id": "fresh", "cwd": "/Users/me/app"]], reply: nil)
        XCTAssertEqual(bar.currentSessionId, "fresh")
        store.handle(["event": "SessionStart", "input": ["session_id": "later", "cwd": "/Users/me/app"]], reply: nil)
        XCTAssertEqual(bar.currentSessionId, "fresh", "only the first one after New")
    }

    func testErrorIsShownAndNothingIsAwaited() {
        bar.openNewSession = { _, _ in "iTerm2: not allowed" }
        bar.openSessions()
        bar.newSession()
        bar.rebuild()
        let pager = bar.itemViews.compactMap { $0 as? PagedTextView }.first
        XCTAssertEqual(pager?.text, "iTerm2: not allowed")
    }
}
