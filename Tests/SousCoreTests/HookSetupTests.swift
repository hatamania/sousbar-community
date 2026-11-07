import Darwin
import XCTest
@testable import SousCore

final class HookSetupTests: XCTestCase {
    private var dir: String!
    override func setUp() {
        dir = NSTemporaryDirectory() + "hooksetup-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    func testDetectsOurHooks() {
        let ours = json(["hooks": ["Stop": [["hooks": [["type": "command", "command": "'/u/.sousbar/bin/sousbar-hook' --agent claude-code"]]]]]])
        XCTAssertTrue(HookSetup.isInstalled(settingsJSON: ours))
    }

    func testOtherOrNoHooksIsNotConnected() {
        XCTAssertFalse(HookSetup.isInstalled(settingsJSON: nil))
        XCTAssertFalse(HookSetup.isInstalled(settingsJSON: Data("not json".utf8)))
        XCTAssertFalse(HookSetup.isInstalled(settingsJSON: json(["model": "opus"])))
        XCTAssertFalse(HookSetup.isInstalled(settingsJSON: json(["hooks": ["Stop": [["hooks": [["command": "/bin/other"]]]]]])))
        XCTAssertFalse(HookSetup.isInstalled(settingsJSON: json(["hooks": ["Stop": "weird"]])))
    }

    func testSyncCopiesOnlyWhenDifferent() throws {
        let bundled = dir + "/bundled", installed = dir + "/home/.sousbar/bin/sousbar-hook"
        FileManager.default.createFile(atPath: bundled, contents: Data("v1".utf8))
        XCTAssertTrue(try HookSetup.syncBinary(from: bundled, to: installed), "missing → copied")
        XCTAssertEqual(FileManager.default.contents(atPath: installed), Data("v1".utf8))
        let mode = (try FileManager.default.attributesOfItem(atPath: installed)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o755)
        XCTAssertFalse(try HookSetup.syncBinary(from: bundled, to: installed), "same → left alone")

        FileManager.default.createFile(atPath: bundled, contents: Data("v2".utf8)) // app updated
        XCTAssertTrue(try HookSetup.syncBinary(from: bundled, to: installed))
        XCTAssertEqual(FileManager.default.contents(atPath: installed), Data("v2".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir + "/home/.sousbar/bin")
        XCTAssertEqual(leftovers, ["sousbar-hook"], "no temp files left behind")
    }

    func testSyncFailsCleanlyWithoutASource() {
        XCTAssertThrowsError(try HookSetup.syncBinary(from: dir + "/nope", to: dir + "/x"))
    }
}
