import XCTest
@testable import SousBar

final class AlwaysRulesTests: XCTestCase {
    func testUsableDropsMalformedEntries() {
        let raw: [Any] = [["type": "addRules"], ["no_type": 1], "string", 3, ["type": 5]]
        XCTAssertEqual(AlwaysRules.usable(raw).count, 1)
        XCTAssertTrue(AlwaysRules.usable(nil).isEmpty)
        XCTAssertTrue(AlwaysRules.usable("not a list").isEmpty)
    }

    func testNothingToDescribe() {
        XCTAssertNil(AlwaysRules.describe([]))
    }

    func testAddRules() {
        let s: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                "rules": [["toolName": "Bash", "ruleContent": "git diff:*"], ["toolName": "Read"]]]
        XCTAssertEqual(AlwaysRules.describe([s]), "Bash(git diff:*), Read in this project")
    }

    func testMcpRuleUsesDisplayName() {
        let s: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "userSettings",
                                "rules": [["toolName": "mcp__github__create_issue"]]]
        XCTAssertEqual(AlwaysRules.describe([s]), "github·create_issue in all projects")
    }

    func testNonAllowBehaviorIsSpelledOut() {
        let s: [String: Any] = ["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]]
        XCTAssertEqual(AlwaysRules.describe([s]), "deny: Bash")
    }

    func testSetModeAndDirectoriesJoined() {
        let mode: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        let dirs: [String: Any] = ["type": "addDirectories", "directories": ["/tmp/x"], "destination": "session"]
        XCTAssertEqual(AlwaysRules.describe([mode, dirs]),
                       "acceptEdits mode for this session; access to /tmp/x for this session")
    }

    func testUnknownTypeStillDescribed() {
        XCTAssertEqual(AlwaysRules.describe([["type": "somethingNew", "destination": "cliArg"]]),
                       "a permission change for this run")
    }
}
