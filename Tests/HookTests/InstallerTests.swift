import XCTest
import SousCore
@testable import sousbar_hook

/// Only the pure merge logic is tested here. install()/uninstall() write to the
/// real ~/.claude/settings.json, so tests never call them.
final class InstallerTests: XCTestCase {
    private let foreign: [String: Any] = ["type": "command", "command": "/usr/local/bin/other-hook"]

    private func commands(_ hooks: [String: Any], _ event: String) -> [String] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testAddsEveryEvent() {
        let hooks = Installer.addOurs(to: [:])
        XCTAssertEqual(Set(hooks.keys), Set(Installer.events.map(\.0)))
        for (event, matcher, timeout) in Installer.events {
            let group = (hooks[event] as? [[String: Any]])?.first
            XCTAssertEqual(group?["matcher"] as? String, matcher, event)
            let hook = (group?["hooks"] as? [[String: Any]])?.first
            XCTAssertEqual(hook?["command"] as? String, Installer.command)
            XCTAssertEqual(hook?["timeout"] as? Int, timeout)
        }
    }

    func testPermissionRequestHasLongTimeout() {
        let entry = Installer.events.first { $0.0 == "PermissionRequest" }
        XCTAssertEqual(entry?.2, 600)
    }

    func testInstallingTwiceDoesNotDuplicate() {
        let once = Installer.addOurs(to: [:])
        let twice = Installer.addOurs(to: once)
        for (event, _, _) in Installer.events {
            XCTAssertEqual(commands(twice, event).count, 1, event)
        }
    }

    func testKeepsOtherHooks() {
        let existing: [String: Any] = [
            "Stop": [["hooks": [foreign]]],
            "PreCompact": [["hooks": [foreign]]],
        ]
        let hooks = Installer.addOurs(to: existing)
        XCTAssertEqual(commands(hooks, "Stop"), ["/usr/local/bin/other-hook", Installer.command])
        XCTAssertEqual(commands(hooks, "PreCompact"), ["/usr/local/bin/other-hook"])
    }

    func testRemoveOursLeavesOthersAndDropsEmptyEvents() {
        let installed = Installer.addOurs(to: ["Stop": [["hooks": [foreign]]]])
        let removed = Installer.removeOurs(from: installed)
        XCTAssertEqual(Array(removed.keys), ["Stop"])
        XCTAssertEqual(commands(removed, "Stop"), ["/usr/local/bin/other-hook"])
    }

    func testRemoveOursKeepsMixedGroup() {
        let mixed: [String: Any] = ["Stop": [["matcher": "*", "hooks": [foreign, ["type": "command", "command": "'/x/sousbar-hook'"]]]]]
        let removed = Installer.removeOurs(from: mixed)
        let group = (removed["Stop"] as? [[String: Any]])?.first
        XCTAssertEqual(group?["matcher"] as? String, "*")
        XCTAssertEqual(commands(removed, "Stop"), ["/usr/local/bin/other-hook"])
    }

    func testRemoveOursIgnoresUnexpectedShapes() {
        let odd: [String: Any] = ["Weird": "not a list", "Stop": [["no_hooks_key": true]]]
        let removed = Installer.removeOurs(from: odd)
        XCTAssertEqual(removed["Weird"] as? String, "not a list")
        XCTAssertEqual((removed["Stop"] as? [[String: Any]])?.count, 1)
    }
}

final class WireTests: XCTestCase {
    func testRoundTripEndsWithNewline() throws {
        let data = try XCTUnwrap(Wire.encode(["event": "Stop", "n": 1]))
        XCTAssertEqual(data.last, 10)
        let decoded = Wire.decode(data.dropLast())
        XCTAssertEqual(decoded?["event"] as? String, "Stop")
    }

    func testInvalidInput() {
        XCTAssertNil(Wire.decode(Data("nope".utf8)))
        XCTAssertNil(Wire.decode(Data("[1,2]".utf8)))
    }
}

final class HookEnvTests: XCTestCase {
    func testHookCapturesTerminalKeysOnly() {
        XCTAssertEqual(Set(HookMode.envKeys), ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "ITERM_SESSION_ID", "__CFBundleIdentifier"])
    }
}

final class RenameMigrationTests: XCTestCase {
    func testHookCommandNamesItsAgent() {
        XCTAssertTrue(Installer.command.hasSuffix("sousbar-hook' --agent claude-code"), Installer.command)
        XCTAssertTrue(Installer.command.contains("/.sousbar/bin/"))
    }

    /// Upgrading from AgentStrip: its entries go, everything else stays, no duplicates.
    func testInstallReplacesAgentStripEntries() {
        let legacy: [String: Any] = ["type": "command", "command": "'/Users/me/.agentstrip/bin/agentstrip-hook'", "timeout": 5]
        let other: [String: Any] = ["type": "command", "command": "/usr/local/bin/other-hook"]
        let before: [String: Any] = [
            "Stop": [["hooks": [legacy]], ["hooks": [other]]],
            "PermissionRequest": [["matcher": "*", "hooks": [legacy]]],
        ]
        let after = Installer.addOurs(to: before)
        let all = after.values.flatMap { ($0 as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []) } }
        let commands = all.compactMap { $0["command"] as? String }
        XCTAssertFalse(commands.contains { $0.contains("agentstrip") }, "old entries removed")
        XCTAssertEqual(commands.filter { $0 == Installer.command }.count, Installer.events.count, "one new entry per event")
        XCTAssertTrue(commands.contains("/usr/local/bin/other-hook"), "other hooks kept")
    }

    func testUninstallAlsoRemovesAgentStripEntries() {
        let legacy: [String: Any] = ["type": "command", "command": "'/x/.agentstrip/bin/agentstrip-hook'"]
        XCTAssertTrue(Installer.removeOurs(from: ["Stop": [["hooks": [legacy]]]]).isEmpty)
    }
}

final class HookArgumentTests: XCTestCase {
    func testAgentFromArguments() {
        XCTAssertEqual(HookMode.agent(from: ["--agent", "claude-code"]), "claude-code")
        XCTAssertEqual(HookMode.agent(from: ["--agent", "cursor"]), "cursor")
        XCTAssertEqual(HookMode.agent(from: []), "claude-code", "entries from before --agent still work")
        XCTAssertNil(HookMode.agent(from: ["--agent"]))
        XCTAssertNil(HookMode.agent(from: ["--agent", ""]))
        XCTAssertNil(HookMode.agent(from: ["bogus"]))
    }
}
