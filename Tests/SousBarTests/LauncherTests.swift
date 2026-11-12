import AppKit
import XCTest
@testable import SousBar

/// The launcher layer: pill → launcher (Claude + modules) → an app's bar → back.
final class LauncherTests: XCTestCase {
    private final class FakeModule: BarModule {
        let id = "rss"
        let title = "RSS"
        let icon = Icon.symbol("dot.radiowaves.up.forward")
        var tint: NSColor?
        var onChange: (() -> Void)?
        var headline = "First headline"
        func barViews() -> [NSView] { [NSTextField(labelWithString: headline)] }
    }

    private var store: Store!
    private var bar: TouchBarController!
    private var module: FakeModule!
    private var presented = 0

    override func setUp() {
        store = Store()
        bar = TouchBarController(store: store)
        bar.systemPresent = { [unowned self] _, _ in presented += 1 }
        bar.systemMinimize = { _ in }
        module = FakeModule()
        bar.modules = [module]
        store.handle(["event": "SessionStart", "input": ["session_id": "a1", "cwd": "/Users/me/web"]], reply: nil)
    }

    private var buttons: [HoldButton] { bar.itemViews.compactMap { $0 as? HoldButton } }
    private func tap(_ title: String) {
        guard let b = buttons.first(where: { $0.title == title }) else { return XCTFail("no \(title) button") }
        b.onComplete?()
    }

    func testOpensOnTheLauncher() {
        bar.present(auto: false)
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(bar.mode, .launcher)
        XCTAssertEqual(buttons.map(\.title), ["Claude", "RSS", ""], "Claude first, then modules, then hide")
    }

    func testClaudeButtonOpensTheSessionHomeWithAWayBack() {
        bar.present(auto: false)
        tap("Claude")
        XCTAssertEqual(bar.mode, .normal)
        buttons.first?.onComplete?() // the launcher button leads Claude's bar
        XCTAssertEqual(bar.mode, .launcher)
    }

    func testModuleGetsTheBarBetweenBackAndHide() {
        bar.present(auto: false)
        tap("RSS")
        XCTAssertEqual(bar.mode, .module("rss"))
        let views = bar.itemViews
        XCTAssertEqual((views.dropFirst().first as? NSTextField)?.stringValue, "First headline")
        XCTAssertEqual((views.last as? HoldButton)?.title, "", "hide stays last")
        (views.first as? HoldButton)?.onComplete?()
        XCTAssertEqual(bar.mode, .launcher)
    }

    func testModuleRedrawsWhenItSaysSo() {
        XCTAssertTrue(bar.open(moduleId: "rss"))
        module.headline = "Breaking"
        module.onChange?()
        XCTAssertEqual((bar.itemViews.dropFirst().first as? NSTextField)?.stringValue, "Breaking")
    }

    func testUnknownModuleIsIgnored() {
        XCTAssertFalse(bar.open(moduleId: "nope"))
        XCTAssertEqual(presented, 0)
    }

    func testApprovalTakesOverTheLauncherAndAutoOpenSkipsIt() {
        bar.present(auto: false)
        store.handle(["event": "PermissionRequest", "input": [
            "session_id": "a1", "tool_name": "Bash", "tool_input": ["command": "ls"]]], reply: ReplyBox())
        bar.rebuild()
        XCTAssertFalse(buttons.contains { $0.title == "RSS" }, "the approval is on the bar, not the launcher")

        let fresh = TouchBarController(store: store)
        fresh.systemPresent = { _, _ in }
        fresh.present(auto: true)
        XCTAssertEqual(fresh.mode, .normal, "an approval opens Claude directly")
    }
}
