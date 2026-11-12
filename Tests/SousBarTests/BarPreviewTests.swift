import AppKit
import XCTest
@testable import SousBar

/// Renders the real bar views offscreen. Always checks the layout fits; set
/// SOUSBAR_BAR_PREVIEW=/some/dir to also write a PNG of each screen.
final class BarPreviewTests: XCTestCase {
    private var store: Store!
    private var bar: TouchBarController!

    override func setUp() {
        store = Store()
        bar = TouchBarController(store: store)
        send("SessionStart", "a1", ["cwd": "/Users/me/sousbar-touchbar-polish", "model": "claude-opus-5-5"])
        send("UserPromptSubmit", "a1")
        send("PreToolUse", "a1", ["tool_name": "Bash", "tool_input": ["command": "swift test"]])
        send("SessionStart", "b2", ["cwd": "/Users/me/web"])
        send("Stop", "b2", ["last_assistant_message": "Done: fixed the **build**. All 48 tests pass now."])
        send("SessionStart", "c3", ["cwd": "/Users/me/api-server"])
        send("Notification", "c3", ["notification_type": "permission_prompt", "message": "Claude needs your permission"])
    }

    private func send(_ event: String, _ sid: String, _ extra: [String: Any] = [:]) {
        var input: [String: Any] = ["session_id": sid]
        for (k, v) in extra { input[k] = v }
        store.handle(["event": event, "input": input], reply: nil)
    }

    private func permission() {
        store.handle(["event": "PermissionRequest", "input": [
            "session_id": "a1", "tool_name": "Bash",
            "tool_input": ["command": "rm -rf ./dist && npm run build"],
            "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                        "rules": [["toolName": "Bash", "ruleContent": "npm run build:*"]]]],
        ]], reply: ReplyBox())
    }

    private func question() {
        store.handle(["event": "PermissionRequest", "input": [
            "session_id": "b2", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "Which checks should run in CI on every pull request?", "header": "CI", "multiSelect": true,
                "options": [["label": "Lint and formatting"], ["label": "Unit tests with coverage"],
                            ["label": "End-to-end browser tests"], ["label": "Type check"]],
            ]]],
        ]], reply: ReplyBox())
    }

    /// A 16" Touch Bar (physical Esc key) is 1004 pt (2008 px, measured with `screencapture -b`):
    /// wider than the 960 pt budget, which is how the buttons drifted off the edge.
    static let touchBarWidth: CGFloat = 1004

    /// Lays the two items out the way the Touch Bar does (left item at the left edge, flexible
    /// space, right item at the right edge) and returns views that stick out of their item.
    @discardableResult
    private func render(_ name: String) -> [NSView] {
        if bar.mode != .reading { bar.rebuild() } // keep the live reader (and its position)
        let left = bar.container, right = bar.rightContainer
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.touchBarWidth, height: 30))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor // the Touch Bar is black; white text needs it
        for item in [left, right] { item.removeFromSuperview(); item.translatesAutoresizingMaskIntoConstraints = true }
        left.frame = NSRect(x: 0, y: 0, width: left.size.width, height: 30)
        right.frame = NSRect(x: Self.touchBarWidth - right.size.width, y: 0, width: right.size.width, height: 30)
        host.addSubview(left)
        host.addSubview(right)
        host.layoutSubtreeIfNeeded()

        var overflow: [NSView] = []
        for item in [left, right] {
            let stack = item.subviews.first
            overflow += (stack?.subviews ?? []).filter { $0.frame.maxX > item.bounds.maxX + 0.5 || $0.frame.minX < -0.5 }
        }
        XCTAssertLessThanOrEqual(left.frame.maxX + TouchBarController.itemGap, right.frame.minX + 0.5,
                                 "\(name): items overlap")

        if let dir = ProcessInfo.processInfo.environment["SOUSBAR_BAR_PREVIEW"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.appearance = NSAppearance(named: .darkAqua)
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        return overflow
    }

    /// Switches session the way you would: chip → active list → tap the one in that folder.
    private func pick(_ folderPrefix: String) {
        bar.mode = .active
        bar.rebuild()
        let buttons = bar.itemViews.compactMap { $0 as? HoldButton }
        let match = buttons.first { ($0.subtitle ?? "").hasPrefix(folderPrefix) }
        XCTAssertNotNil(match, "no session in \(folderPrefix)")
        match?.onComplete?()
    }

    func testHomeWhileWorking() {
        pick("sousbar")
        XCTAssertEqual(render("1-home-working"), [])
        let pager = bar.itemViews.compactMap { $0 as? PagedTextView }.first
        XCTAssertEqual(pager?.isAnimating, true, "a working session animates")
    }

    func testHomeInTerminalDoesNotAnimate() {
        pick("api-server")
        bar.rebuild()
        let pager = bar.itemViews.compactMap { $0 as? PagedTextView }.first
        XCTAssertEqual(pager?.isAnimating, false)
        XCTAssertEqual(pager?.text, "Claude needs your permission")
    }

    func testHomeWithReply() {
        pick("web") // the way a tap would: through the picker
        XCTAssertEqual(bar.mode, .normal)
        XCTAssertEqual(render("2-home-reply"), [])
    }

    func testPermission() {
        permission()
        XCTAssertEqual(render("3-permission"), [])
    }

    func testQuestionFitsWithLongOptions() {
        question()
        XCTAssertEqual(render("4-question"), [])
    }

    func testSessionsPickerShowsFolderHistory() throws {
        // A fake history folder for a1, with two past conversations.
        let dir = NSTemporaryDirectory() + "bar-history-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for (id, title, age) in [("a1", "Polish the Touch Bar UI", 0.0), ("p1", "Add unit tests for the store", 3600.0),
                                 ("p2", "Audit app features and suggest the next move", 86400.0 * 2)] {
            let line = String(data: try JSONSerialization.data(withJSONObject: ["type": "ai-title", "aiTitle": title]), encoding: .utf8)!
            FileManager.default.createFile(atPath: "\(dir)/\(id).jsonl", contents: Data((line + "\n").utf8),
                                           attributes: [.modificationDate: Date().addingTimeInterval(-age)])
        }
        send("UserPromptSubmit", "a1", ["transcript_path": "\(dir)/a1.jsonl"])

        pick("sousbar")
        bar.rebuild()
        bar.openSessions() // what the list button does
        XCTAssertEqual(bar.mode, .sessions)
        XCTAssertTrue(bar.itemViews.contains { ($0 as? NSTextField)?.stringValue == "sousbar-touchbar-polish" },
                      "the folder's name starts the row")
        let loaded = expectation(description: "history loaded")
        func poll() {
            let titles = bar.itemViews.compactMap { ($0 as? HoldButton)?.title } ?? []
            if titles.contains(where: { $0.hasPrefix("Add unit tests") }) { loaded.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.bar.rebuild(); poll() } }
        }
        poll()
        wait(for: [loaded], timeout: 3)
        let titles = bar.itemViews.compactMap { ($0 as? HoldButton)?.title } ?? []
        let buttons = bar.itemViews.compactMap { $0 as? HoldButton }
        XCTAssertTrue(buttons.contains { $0.title == "Polish the Touch Bar UI" && $0.subtitle == "Working" }, "\(titles)")
        XCTAssertTrue(buttons.contains { $0.title.hasPrefix("Audit app features") && $0.subtitle == "2d ago" }, "\(titles)")
        XCTAssertFalse(buttons.contains { ($0.subtitle ?? "").contains("New reply") || ($0.subtitle ?? "").contains("In terminal") },
                       "other folders' sessions aren't in this folder's history: \(titles)")
        XCTAssertEqual(render("5-sessions"), [])
    }

    func testChipOpensAllActiveSessions() {
        bar.rebuild()
        (bar.itemViews[1] as? HoldButton)?.onComplete?() // tap the chip (after the launcher button)
        XCTAssertEqual(bar.mode, .active)
        let buttons = bar.itemViews.compactMap { $0 as? HoldButton }
        let subtitles = Set(buttons.compactMap(\.subtitle))
        XCTAssertTrue(subtitles.isSuperset(of: ["web · New reply", "api-server · In terminal"]), "\(subtitles)")
        XCTAssertTrue(subtitles.contains { $0.hasPrefix("sousbar-") && $0.hasSuffix(" · Working") },
                      "a long folder is shortened, the status stays: \(subtitles)")
        XCTAssertTrue(buttons.contains { $0.title == "New session" }, "a name on every entry")
        XCTAssertEqual(render("5a-active"), [])
    }

    func testReadingScreen() {
        pick("web")
        bar.startReading()
        XCTAssertEqual(bar.mode, .reading)
        let reader = bar.itemViews.compactMap { $0 as? SpeedReaderView }.first
        XCTAssertNotNil(reader)
        XCTAssertTrue(reader?.isPlaying ?? false)
        reader?.engine.advance() // "the" → show a mid-sentence word
        reader?.engine.advance()
        XCTAssertEqual(render("8-reading"), [])
    }

    func testPlayExplainsWhyWhileWorking() {
        pick("sousbar")
        bar.startReading()
        XCTAssertEqual(bar.mode, .normal, "nothing to read while Claude is still working")
        bar.rebuild() // the real bar redraws on flash; offscreen it doesn't
        let pager = bar.itemViews.compactMap { $0 as? PagedTextView }.first
        XCTAssertEqual(pager?.text, "Claude is still working. Play the reply when it's done.")
    }

    func testPlayButtonIsAlwaysTappable() {
        pick("api-server") // no reply known for this one
        bar.rebuild()
        let buttons = bar.itemViews.compactMap { $0 as? HoldButton }
        XCTAssertTrue(buttons.allSatisfy(\.isEnabled), "no greyed-out buttons on the home row")
        bar.startReading()
        bar.rebuild()
        let pager = bar.itemViews.compactMap { $0 as? PagedTextView }.first
        XCTAssertEqual(pager?.text, "No reply to read yet in api-server")
    }

    /// Seen on the real bar: "Sent to sousbar" covered a new approval's command.
    func testNewApprovalClearsLeftoverMessage() throws {
        pick("sousbar")
        bar.startReading() // working → leaves a message on the bar
        bar.rebuild()
        XCTAssertEqual(bar.itemViews.compactMap { $0 as? PagedTextView }.first?.text,
                       "Claude is still working. Play the reply when it's done.")
        permission()
        bar.handleNewPending(try XCTUnwrap(store.pending.first))
        bar.rebuild()
        XCTAssertEqual(bar.itemViews.compactMap { $0 as? PagedTextView }.first?.text,
                       "Bash · rm -rf ./dist && npm run build", "the approval shows what it's asking")
    }

    func testModelAndEffortPickers() {
        bar.mode = .model
        XCTAssertEqual(render("6-model"), [])
        bar.mode = .effort
        XCTAssertEqual(render("7-effort"), [])
    }

    func testHideIsAlwaysLast() {
        for mode in [TouchBarController.Mode.normal, .active, .sessions, .model, .effort, .launcher] {
            bar.mode = mode
            bar.rebuild()
            let last = bar.itemViews.last as? HoldButton
            XCTAssertNotNil(last?.icon, "\(mode)")
            XCTAssertEqual(last?.title, "", "\(mode)")
        }
    }

    /// Regression: the bar was one fixed-width item that macOS centered, so on a wider Touch Bar
    /// the buttons stopped short of the right edge. Every screen must end flush right.
    func testButtonsAreFlushRightOnEveryScreen() {
        func check(_ label: String) {
            render("flush-\(label)")
            let right = bar.rightContainer
            let hide = try? XCTUnwrap(bar.itemViews.last)
            let hideMaxX = hide.map { right.convert($0.frame, from: $0.superview).maxX + right.frame.minX } ?? 0
            XCTAssertEqual(hideMaxX, Self.touchBarWidth, accuracy: 0.5, "\(label): hide button not at the right edge")
            XCTAssertTrue(bar.rightContainer.subviews.first?.subviews.contains { $0 === hide } ?? false, "\(label)")
        }
        check("home")
        for (mode, label) in [(TouchBarController.Mode.active, "active"), (.sessions, "history"), (.model, "model"), (.effort, "effort"), (.launcher, "launcher")] {
            bar.mode = mode
            check(label)
        }
        bar.mode = .normal
        permission()
        check("permission")
    }

    func testFeedsScreenFits() {
        let feeds = FeedStore(defaults: UserDefaults(suiteName: "sousbar-preview-\(UUID().uuidString)")!)
        feeds.fetch = { _, _ in }
        feeds.token = { _ in nil }
        feeds.storeToken = { _, _ in }
        let module = FeedsModule(store: feeds)
        bar.modules = [module]
        let id = feeds.add(name: "Jira", url: "https://x/activity", username: nil, token: nil).id
        let ok = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: [:])
        feeds.received(id, FeedStoreTests.rss(["a"]), ok, nil)
        let long = "<rss><channel><item><guid>b</guid><title>Ann Lee changed the status to Done on SB-12 - Touch Bar launcher with modules for feeds and more and even more words</title>" +
            "<link>https://x/b</link><pubDate>\(Date().addingTimeInterval(-300).rfc822)</pubDate></item></channel></rss>"
        bar.systemPresent = { _, _ in }
        Settings.feedPeek = false
        feeds.received(id, Data(long.utf8), ok, nil)
        bar.mode = .module("feeds")
        XCTAssertEqual(render("9-feeds"), [])
        bar.mode = .launcher
        XCTAssertEqual(render("9-launcher"), [])
        Settings.feedPeek = true
    }

    func testSplitPutsButtonsRightOfTheText() {
        let pager = PagedTextView()
        let a = HoldButton("A"), b = HoldButton("B"), chip = HoldButton("chip")
        XCTAssertEqual(TouchBarController.splitIndex([chip, pager, a, b]), 2)
        XCTAssertEqual(TouchBarController.splitIndex([a, b]), 1, "no text: only the last button goes right")
        let spacer = NSView()
        XCTAssertEqual(TouchBarController.splitIndex([a, spacer, b]), 2)
    }

    func testChipHasFixedWidth() {
        render("chip")
        let chip = bar.itemViews.dropFirst().first // after the launcher button
        XCTAssertEqual(chip?.frame.width ?? 0, TouchBarController.chipWidth, accuracy: 0.5)
    }
}

private extension Date {
    var rfc822: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: self)
    }
}
