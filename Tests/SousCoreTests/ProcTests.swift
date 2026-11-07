import Darwin
import Foundation
import XCTest
@testable import SousCore

final class ProcTests: XCTestCase {
    func testOwnProcessIsAlive() throws {
        let me = try XCTUnwrap(Proc.identity(getpid()))
        XCTAssertEqual(me.pid, getpid())
        XCTAssertGreaterThan(me.startSec, 0)
        XCTAssertTrue(Proc.isAlive(me))
    }

    func testParentAndName() {
        XCTAssertEqual(Proc.parent(getpid()), getppid())
        XCTAssertFalse((Proc.name(getpid()) ?? "").isEmpty)
    }

    func testSameIdWithDifferentStartTimeIsNotAlive() throws {
        let me = try XCTUnwrap(Proc.identity(getpid()))
        let recycled = ProcessIdentity(pid: me.pid, startSec: me.startSec - 1000, startUsec: me.startUsec)
        XCTAssertFalse(Proc.isAlive(recycled), "a reused PID must not count as the old session")
    }

    func testExitedProcessIsNotAlive() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        let id = try XCTUnwrap(Proc.identity(p.processIdentifier))
        XCTAssertTrue(Proc.isAlive(id))
        p.terminate()
        p.waitUntilExit()
        XCTAssertFalse(Proc.isAlive(id))
    }

    func testBadPids() {
        XCTAssertNil(Proc.identity(0))
        XCTAssertNil(Proc.identity(-5))
        XCTAssertNil(Proc.parent(0))
    }

    func testFirstNonWrapperSkipsShells() {
        let chain: [(pid: pid_t, name: String)] = [(10, "sh"), (11, "zsh"), (12, "2.1.319"), (13, "zsh")]
        XCTAssertEqual(Proc.firstNonWrapper(chain), 12)
        XCTAssertEqual(Proc.firstNonWrapper([(5, "/bin/bash"), (6, "node")]), 6)
        XCTAssertEqual(Proc.firstNonWrapper([(5, "BASH"), (6, "claude")]), 6)
        XCTAssertNil(Proc.firstNonWrapper([(5, "sh"), (6, "env")]))
        XCTAssertNil(Proc.firstNonWrapper([]))
    }

    func testAgentAncestorSkipsShellParent() throws {
        // A real "sh -c" whose child reports its agent ancestor: the shell is skipped
        // and the result is this test process.
        let me = try XCTUnwrap(Proc.identity(getpid()))
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 5; true"] // two commands, so sh can't exec into sleep
        try sh.run()
        defer { sh.terminate() }
        var sleepPid: pid_t?
        for _ in 0..<50 where sleepPid == nil {
            usleep(20_000)
            sleepPid = childOf(sh.processIdentifier)
        }
        let child = try XCTUnwrap(sleepPid, "sleep didn't start")
        XCTAssertEqual(Proc.agentAncestor(from: Proc.parent(child)!), me)
        kill(child, SIGTERM)
    }

    private func childOf(_ parent: pid_t) -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0 ? pids[0] : nil
    }

    func testWireRoundTrip() {
        let id = ProcessIdentity(pid: 42, startSec: 1_700_000_000, startUsec: 123)
        let data = try! JSONSerialization.data(withJSONObject: id.wire)
        XCTAssertEqual(ProcessIdentity(wire: Wire.decode(data)), id)
        XCTAssertNil(ProcessIdentity(wire: nil))
        XCTAssertNil(ProcessIdentity(wire: ["pid": 0, "start_sec": 1, "start_usec": 1]))
        XCTAssertNil(ProcessIdentity(wire: ["pid": 3]))
    }
}
