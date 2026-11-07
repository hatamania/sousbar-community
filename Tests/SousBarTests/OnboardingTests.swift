import XCTest
@testable import SousBar

final class ControlStripTests: XCTestCase {
    func testModesThatShowTheControlStrip() {
        XCTAssertTrue(ControlStrip.isShown(mode: nil), "unset is the macOS default, which shows it")
        XCTAssertTrue(ControlStrip.isShown(mode: "appWithControlStrip"))
        XCTAssertTrue(ControlStrip.isShown(mode: "fullControlStrip"))
    }

    func testModesThatHideIt() {
        XCTAssertFalse(ControlStrip.isShown(mode: "app"))
        XCTAssertFalse(ControlStrip.isShown(mode: "functionKeys"))
        XCTAssertFalse(ControlStrip.isShown(mode: "workflows"))
    }
}
