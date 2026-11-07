import Foundation
import Darwin

/// Where everything lives. The socket is a Unix domain socket (not a TCP port),
/// so web pages in your browser can never reach it, and it is chmod 600.
public enum SousPaths {
    public static var baseDir: String { NSHomeDirectory() + "/.sousbar" }
    public static var socketPath: String { baseDir + "/sousbar.sock" }
    public static var hookBinary: String { baseDir + "/bin/sousbar-hook" }
}

/// One JSON object per line, in each direction.
public enum Wire {
    public static func encode(_ obj: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        data.append(10) // "\n"
        return data
    }

    public static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public enum UnixSocket {
    private static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func disableSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Returns nil if nothing is listening (e.g. the app isn't running).
    public static func connect(path: String) -> Int32? {
        guard var addr = makeAddress(path) else { return nil }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        disableSigPipe(fd)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if result != 0 {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        guard var addr = makeAddress(path) else { throw SocketError("Socket path too long: \(path)") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed (errno \(errno))") }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw SocketError("bind() failed (errno \(errno))")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw SocketError("listen() failed (errno \(errno))")
        }
        return fd
    }

    public static func configureAccepted(_ fd: Int32) {
        disableSigPipe(fd)
    }

    public static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads until newline or EOF. Returns nil on EOF with no data.
    public static func readLine(_ fd: Int32, maxBytes: Int = 16 << 20) -> Data? {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while result.count < maxBytes {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return result.isEmpty ? nil : result }
            if let nl = chunk[0..<n].firstIndex(of: 10) {
                result.append(contentsOf: chunk[0..<nl])
                return result
            }
            result.append(contentsOf: chunk[0..<n])
        }
        return result
    }

    /// True if the other side has hung up (e.g. Claude Code killed the hook).
    public static func peerClosed(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return false }
        if p.revents & Int16(POLLHUP) != 0 || p.revents & Int16(POLLERR) != 0 { return true }
        if p.revents & Int16(POLLIN) != 0 {
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, MSG_PEEK) == 0
        }
        return false
    }
}

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A process, pinned by its start time so a recycled PID never looks like the same process.
public struct ProcessIdentity: Hashable {
    public let pid: Int32
    public let startSec: Int
    public let startUsec: Int

    public init(pid: Int32, startSec: Int, startUsec: Int) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }

    public var wire: [String: Any] { ["pid": Int(pid), "start_sec": startSec, "start_usec": startUsec] }

    public init?(wire: Any?) {
        guard let d = wire as? [String: Any],
              let pid = (d["pid"] as? NSNumber)?.int32Value,
              let sec = (d["start_sec"] as? NSNumber)?.intValue,
              let usec = (d["start_usec"] as? NSNumber)?.intValue, pid > 0 else { return nil }
        self.init(pid: pid, startSec: sec, startUsec: usec)
    }
}

public enum Proc {
    /// Things a hook command may be wrapped in. The first ancestor that isn't one of these is Claude Code.
    public static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "timeout"]

    private static func info(_ pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0) == 0,
              size > 0, kp.kp_proc.p_pid == pid else { return nil }
        return kp
    }

    public static func identity(_ pid: pid_t) -> ProcessIdentity? {
        guard let kp = info(pid) else { return nil }
        let t = kp.kp_proc.p_starttime
        return ProcessIdentity(pid: pid, startSec: Int(t.tv_sec), startUsec: Int(t.tv_usec))
    }

    public static func parent(_ pid: pid_t) -> pid_t? {
        guard let kp = info(pid) else { return nil }
        let ppid = kp.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    public static func name(_ pid: pid_t) -> String? {
        guard var kp = info(pid) else { return nil }
        return withUnsafeBytes(of: &kp.kp_proc.p_comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// True while that exact process (same PID *and* start time) is still running.
    public static func isAlive(_ id: ProcessIdentity) -> Bool {
        identity(id.pid) == id
    }

    /// Picks the first process in `chain` (nearest first) that isn't a shell or wrapper.
    public static func firstNonWrapper(_ chain: [(pid: pid_t, name: String)]) -> pid_t? {
        chain.first { !wrappers.contains(($0.name as NSString).lastPathComponent.lowercased()) }?.pid
    }

    /// The Claude Code process that ran this hook: the nearest ancestor that isn't a shell.
    public static func agentAncestor(from start: pid_t = getppid(), maxDepth: Int = 6) -> ProcessIdentity? {
        var chain: [(pid: pid_t, name: String)] = []
        var pid: pid_t? = start
        while let p = pid, p > 1, chain.count < maxDepth {
            chain.append((p, name(p) ?? ""))
            pid = parent(p)
        }
        return firstNonWrapper(chain).flatMap(identity)
    }
}

/// A Claude Code process found running in a terminal, so the app can list it before it sends a hook event.
public struct RunningAgent: Equatable {
    public let identity: ProcessIdentity
    public let cwd: String
    /// Only the terminal keys the hook would send (TMUX, TMUX_PANE, TERM_PROGRAM, ITERM_SESSION_ID, __CFBundleIdentifier).
    public let env: [String: String]

    public init(identity: ProcessIdentity, cwd: String, env: [String: String]) {
        self.identity = identity
        self.cwd = cwd
        self.env = env
    }
}

extension Proc {
    public static let terminalEnvKeys: Set<String> = ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "ITERM_SESSION_ID", "__CFBundleIdentifier"]

    public static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    public struct ProcArgs: Equatable {
        public let exec: String
        public let argv: [String]
        public let env: [String: String]
    }

    /// Executable path, arguments and environment (same-user processes only), from KERN_PROCARGS2.
    public static func procArgs(_ pid: pid_t) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    public static func environment(_ pid: pid_t) -> [String: String]? { procArgs(pid)?.env }

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argv[argc], then env "KEY=VALUE" strings.
    public static func parseProcArgs(_ buf: [UInt8]) -> ProcArgs? {
        guard buf.count > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        func readString() -> String {
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        func skipNuls() { while i < buf.count, buf[i] == 0 { i += 1 } }
        let exec = readString(); skipNuls()
        var argv: [String] = []
        for _ in 0..<max(0, argc) where i < buf.count { argv.append(readString()); skipNuls() }
        var env: [String: String] = [:]
        while i < buf.count, buf[i] != 0 {
            let entry = readString()
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            i += 1
        }
        return ProcArgs(exec: exec, argv: argv, env: env)
    }

    /// Is this Claude Code? The kernel name isn't enough: the native installer runs the binary
    /// as ~/.local/share/claude/versions/<version>, so its process name is e.g. "2.1.319".
    public static func isClaudeCode(name: String?, args: ProcArgs) -> Bool {
        let argv0 = (args.argv.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        return name == "claude" || argv0 == "claude"
            || (args.exec as NSString).lastPathComponent == "claude"
            || args.exec.contains("/claude/versions/")
    }

    /// Claude Code CLI sessions running in a terminal (not ones hosted by the Claude desktop app).
    public static func runningAgents() -> [RunningAgent] {
        let found: [(pid: pid_t, args: ProcArgs)] = allPids().compactMap { pid in
            guard pid != getpid(), let args = procArgs(pid), isClaudeCode(name: name(pid), args: args) else { return nil }
            return (pid, args)
        }
        let top = Set(topLevel(found.map(\.pid), parent: parent))
        return found.compactMap { f in
            guard top.contains(f.pid), isTerminalSession(f.args.env),
                  let cwd = cwd(f.pid), let id = identity(f.pid) else { return nil }
            return RunningAgent(identity: id, cwd: cwd, env: f.args.env.filter { terminalEnvKeys.contains($0.key) })
        }
    }

    /// Drops processes started (directly or a few levels down) by another one in the list,
    /// e.g. a short-lived `claude` that a session runs as a helper.
    public static func topLevel(_ pids: [pid_t], parent: (pid_t) -> pid_t?, maxDepth: Int = 8) -> [pid_t] {
        let set = Set(pids)
        return pids.filter { pid in
            var p = parent(pid)
            for _ in 0..<maxDepth {
                guard let cur = p, cur > 1 else { return true }
                if set.contains(cur) { return false }
                p = parent(cur)
            }
            return true
        }
    }

    /// In a terminal (tmux or a terminal app), and not started by the desktop app.
    public static func isTerminalSession(_ env: [String: String]) -> Bool {
        if env["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop" { return false }
        return env["TMUX"] != nil || env["TERM_PROGRAM"] != nil
    }
}

/// Shared by the app and the installer: is SousBar connected to Claude Code, and keeping the
/// installed hook binary in step with the one shipped inside the app.
public enum HookSetup {
    public static var settingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

    /// True if any hook command in this settings.json is ours.
    public static func isInstalled(settingsJSON data: Data?) -> Bool {
        guard let data, let root = Wire.decode(data), let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    if (hook["command"] as? String)?.contains("sousbar-hook") == true { return true }
                }
            }
        }
        return false
    }

    public static func isInstalled() -> Bool {
        isInstalled(settingsJSON: FileManager.default.contents(atPath: settingsPath))
    }

    /// Copies `bundled` to `installed` when it's missing or different, atomically, mode 755.
    /// Returns true if it wrote a new copy.
    @discardableResult
    public static func syncBinary(from bundled: String, to installed: String) throws -> Bool {
        let fm = FileManager.default
        guard let new = fm.contents(atPath: bundled) else { throw SocketError("Missing \(bundled)") }
        if fm.contents(atPath: installed) == new { return false }
        let dir = (installed as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod((dir as NSString).deletingLastPathComponent, 0o700) // ~/.sousbar
        let temp = dir + "/.sousbar-hook.\(getpid()).tmp"
        guard fm.createFile(atPath: temp, contents: new, attributes: [.posixPermissions: 0o755]) else {
            throw SocketError("Couldn't write \(temp)")
        }
        guard rename(temp, installed) == 0 else {
            unlink(temp)
            throw SocketError("Couldn't replace \(installed) (errno \(errno))")
        }
        return true
    }
}
