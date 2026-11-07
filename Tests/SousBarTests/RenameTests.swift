import XCTest
import SousCore
@testable import SousBar

final class RenameTests: XCTestCase {
    private var old: UserDefaults!
    private var new: UserDefaults!
    private var names: [String] = []

    override func setUp() {
        names = ["test.old.\(UUID().uuidString)", "test.new.\(UUID().uuidString)"]
        old = UserDefaults(suiteName: names[0])
        new = UserDefaults(suiteName: names[1])
    }

    override func tearDown() {
        names.forEach { UserDefaults().removePersistentDomain(forName: $0) }
    }

    func testSettingsCarryOverOnce() {
        old.set(450, forKey: "readingWPM")
        old.set(120.0, forKey: "approvalTimeout")
        old.set("vi-VN", forKey: "voiceLocale")
        new.set(true, forKey: "autoRead") // already set in the new app: not overwritten
        old.set(false, forKey: "autoRead")

        let copied = Settings.migrateFromLegacy(from: old, to: new)
        XCTAssertEqual(Set(copied), ["readingWPM", "approvalTimeout", "voiceLocale"])
        XCTAssertEqual(new.integer(forKey: "readingWPM"), 450)
        XCTAssertEqual(new.bool(forKey: "autoRead"), true)

        old.set(700, forKey: "readingWPM")
        XCTAssertEqual(Settings.migrateFromLegacy(from: old, to: new), [], "only the first launch copies")
        XCTAssertEqual(new.integer(forKey: "readingWPM"), 450)
    }

    func testNoOldSettingsIsFine() {
        XCTAssertEqual(Settings.migrateFromLegacy(from: nil, to: new), [])
    }

    func testEventsRecordWhichAgentSentThem() {
        let store = Store()
        store.handle(["event": "SessionStart", "input": ["session_id": "s"], "client": "claude-code"], reply: nil)
        XCTAssertEqual(store.session("s")?.client, "claude-code")
        store.handle(["event": "SessionStart", "input": ["session_id": "t"]], reply: nil)
        XCTAssertEqual(store.session("t")?.client, "claude-code", "older hooks without the field")
    }

    func testPathsUseTheNewName() {
        XCTAssertTrue(SousPaths.baseDir.hasSuffix("/.sousbar"))
        XCTAssertTrue(SousPaths.socketPath.hasSuffix("/.sousbar/sousbar.sock"))
        XCTAssertTrue(SousPaths.hookBinary.hasSuffix("/.sousbar/bin/sousbar-hook"))
    }
}
