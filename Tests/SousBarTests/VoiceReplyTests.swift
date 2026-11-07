import AppKit
import XCTest
@testable import SousBar

final class VoiceReplyTests: XCTestCase {
    func testDenyMessageWithoutReasonIsTheOldDefault() {
        XCTAssertEqual(Decision.denyMessage(), "The user denied this from the Touch Bar.")
        XCTAssertEqual(Decision.denyMessage(reason: "  \n "), "The user denied this from the Touch Bar.")
    }

    func testDenyMessageCarriesTheReason() {
        XCTAssertEqual(Decision.denyMessage(reason: " use pnpm instead \n"),
                       "The user denied this from the Touch Bar and said: use pnpm instead")
    }

    func testOtherAnswerAlone() {
        XCTAssertEqual(Decision.otherAnswer(selected: [], spoken: " yarn berry "), "yarn berry")
    }

    func testOtherAnswerAfterTickedOptions() {
        XCTAssertEqual(Decision.otherAnswer(selected: ["Lint", "E2E"], spoken: "type check"), "Lint, E2E, type check")
    }

    func testEmptySpokenAnswerKeepsTicks() {
        XCTAssertEqual(Decision.otherAnswer(selected: ["Lint"], spoken: ""), "Lint")
    }

    func testVoiceTargetItemId() {
        let id = UUID()
        XCTAssertNil(VoiceTarget.prompt(sessionId: "s").itemId)
        XCTAssertEqual(VoiceTarget.denyReason(itemId: id).itemId, id)
        XCTAssertEqual(VoiceTarget.otherAnswer(itemId: id, questionIndex: 1).itemId, id)
        XCTAssertNotEqual(VoiceTarget.otherAnswer(itemId: id, questionIndex: 0),
                          VoiceTarget.otherAnswer(itemId: id, questionIndex: 1))
    }

    func testDeniedWithReasonReachesTheHook() throws {
        let store = Store()
        let box = ReplyBox()
        store.handle(["event": "PermissionRequest",
                      "input": ["session_id": "s", "tool_name": "Bash", "tool_input": ["command": "npm i"]]],
                     reply: box)
        store.resolve(try XCTUnwrap(store.pending.first),
                      output: Decision.deny(Decision.denyMessage(reason: "use pnpm")))
        let decision = (box.output?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertEqual(decision?["message"] as? String, "The user denied this from the Touch Bar and said: use pnpm")
    }
}

final class FitLabelsTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    private func rowWidth(_ labels: [String]) -> CGFloat {
        labels.reduce(0) { $0 + max(44, ceil(($1 as NSString).size(withAttributes: [.font: font]).width) + 22) + 6 }
    }

    func testShortLabelsUntouched() {
        XCTAssertEqual(TextTools.fitLabels(["pnpm", "npm", "bun"], budget: 500, font: font), ["pnpm", "npm", "bun"])
    }

    func testLongLabelsStartAt18() {
        let out = TextTools.fitLabels([String(repeating: "a", count: 30)], budget: 1000, font: font)
        XCTAssertEqual(out.first?.count, 18)
    }

    func testShrinksToFitBudget() {
        let labels = (1...4).map { "Option number \($0) is long" }
        let budget: CGFloat = 400
        let out = TextTools.fitLabels(labels, budget: budget, font: font)
        XCTAssertLessThanOrEqual(rowWidth(out), budget)
        XCTAssertTrue(out.allSatisfy { $0.hasSuffix("…") })
    }

    func testShortLabelsStayWholeWhileLongOnesShrink() {
        let labels = ["Lint and formatting", "Unit tests with coverage", "End-to-end browser tests", "Type check"]
        let out = TextTools.fitLabels(labels, budget: 420, font: font)
        XCTAssertLessThanOrEqual(rowWidth(out), 420)
        XCTAssertEqual(out[3], "Type check")
        XCTAssertTrue(out[1].hasSuffix("…"))
    }

    func testStopsAtFloorWhenBudgetIsImpossible() {
        let out = TextTools.fitLabels(["abcdefghij", "klmnopqrst"], budget: 10, font: font)
        XCTAssertEqual(out, ["abc…", "klm…"])
    }

    func testDefaultBarFitsFourLongOptionsWithRoomForQuestion() {
        let fixed: CGFloat = 608
        let labels = (1...4).map { _ in String(repeating: "W", count: 30) }
        let out = TextTools.fitLabels(labels, budget: 960 - fixed, font: font)
        XCTAssertLessThanOrEqual(rowWidth(out), 960 - fixed)
    }
}
