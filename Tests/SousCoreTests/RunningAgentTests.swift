import Darwin
import XCTest
@testable import SousCore

final class RunningAgentTests: XCTestCase {
    private func procArgs(argc: Int32, exec: String, argv: [String], env: [String]) -> [UInt8] {
        var b = withUnsafeBytes(of: argc) { Array($0) }
        b += Array(exec.utf8) + [0, 0, 0]          // exec path + padding
        for a in argv { b += Array(a.utf8) + [0] }
        for e in env { b += Array(e.utf8) + [0] }
        return b + [0, 0]
    }

    func testParseProcArgs() {
        let buf = procArgs(argc: 2, exec: "/x/claude", argv: ["claude", "--resume"],
                           env: ["TERM_PROGRAM=iTerm.app", "ITERM_SESSION_ID=w1t1p0:ABC", "EMPTY=", "A=b=c"])
        let parsed = Proc.parseProcArgs(buf)
        XCTAssertEqual(parsed?.exec, "/x/claude")
        XCTAssertEqual(parsed?.argv, ["claude", "--resume"])
        XCTAssertEqual(parsed?.env, ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w1t1p0:ABC", "EMPTY": "", "A": "b=c"])
    }

    func testParseProcArgsGarbage() {
        XCTAssertNil(Proc.parseProcArgs([1, 2]))
        XCTAssertEqual(Proc.parseProcArgs(procArgs(argc: 0, exec: "/x", argv: [], env: []))?.env, [:])
        _ = Proc.parseProcArgs(withUnsafeBytes(of: Int32(99)) { Array($0) } + [65, 0]) // argc lies: no crash
    }

    func testRecognizesClaudeCodeHowEverItWasInstalled() {
        func args(_ exec: String, _ argv0: String) -> Proc.ProcArgs { .init(exec: exec, argv: [argv0], env: [:]) }
        // Native installer: kernel name is the version number.
        XCTAssertTrue(Proc.isClaudeCode(name: "2.1.319", args: args("/Users/me/.local/share/claude/versions/2.1.319", "claude")))
        XCTAssertTrue(Proc.isClaudeCode(name: "claude", args: args("/opt/homebrew/bin/claude", "claude")))
        XCTAssertTrue(Proc.isClaudeCode(name: "node", args: args("/usr/local/bin/node", "/usr/local/bin/claude")))
        XCTAssertFalse(Proc.isClaudeCode(name: "zsh", args: args("/bin/zsh", "-zsh")))
        XCTAssertFalse(Proc.isClaudeCode(name: "2.1.319", args: args("/usr/bin/something", "something")))
    }

    func testNestedClaudeProcessesAreDropped() {
        // 100 = session, 101 = shell it spawned, 102 = claude helper under that shell; 200 = another session.
        let parents: [pid_t: pid_t] = [100: 50, 50: 1, 101: 100, 102: 101, 200: 60, 60: 1]
        XCTAssertEqual(Proc.topLevel([100, 102, 200], parent: { parents[$0] }), [100, 200])
        XCTAssertEqual(Proc.topLevel([], parent: { parents[$0] }), [])
    }

    func testTerminalSessionFilter() {
        XCTAssertTrue(Proc.isTerminalSession(["TERM_PROGRAM": "iTerm.app"]))
        XCTAssertTrue(Proc.isTerminalSession(["TMUX": "/tmp/t,1,0"]))
        XCTAssertFalse(Proc.isTerminalSession(["__CFBundleIdentifier": "com.anthropic.claudefordesktop",
                                               "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]))
        XCTAssertFalse(Proc.isTerminalSession(["TERM_PROGRAM": "x", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]))
        XCTAssertFalse(Proc.isTerminalSession([:]))
    }

    func testOwnEnvironmentAndCwdAreReadable() {
        let env = Proc.environment(getpid())
        XCTAssertEqual(env?["HOME"], ProcessInfo.processInfo.environment["HOME"])
        XCTAssertEqual(Proc.cwd(getpid()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertTrue(Proc.allPids().contains(getpid()))
    }

    func testRunningAgentsAreTerminalClaudeProcesses() {
        let agents = Proc.runningAgents()
        print("RUNNING", agents.map { "\($0.identity.pid) \($0.cwd) \($0.env)" })
        for a in agents {
            XCTAssertTrue(Proc.isClaudeCode(name: Proc.name(a.identity.pid), args: Proc.procArgs(a.identity.pid)!))
            XCTAssertFalse(a.cwd.isEmpty)
            XCTAssertTrue(a.env.keys.allSatisfy(Proc.terminalEnvKeys.contains))
        }
    }
}
