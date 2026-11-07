import Foundation
import Darwin
import SousCore

/// Listens on ~/.sousbar/sousbar.sock. Each hook invocation is one connection.
final class HookServer {
    /// Called on the main thread. ReplyBox is non-nil when the hook is waiting for an answer.
    var onMessage: (([String: Any], ReplyBox?) -> Void)?
    /// Called on the main thread when a waiting hook went away (e.g. you pressed Esc in Claude Code).
    var onCancelled: ((ReplyBox) -> Void)?
    /// Called on the main thread when the socket thread's deadline handed a request to the terminal.
    var onTimedOut: ((ReplyBox) -> Void)?

    private var listenFD: Int32 = -1
    private let socketPath: String

    /// How long a waiting hook may go unanswered before this thread hands it back to the terminal
    /// itself. The main thread has its own (shorter) timeout; this one still works if the main
    /// thread is stuck. Read on the socket thread, so it must be thread-safe.
    var replyDeadline: () -> TimeInterval = HookServer.defaultDeadline

    /// The approval timeout plus a little grace, or just under the hook's 600 s cap for "never".
    static func defaultDeadline() -> TimeInterval {
        let timeout = Settings.approvalTimeout
        return timeout > 0 ? min(timeout + 5, 590) : 590
    }

    init(socketPath: String = SousPaths.socketPath) {
        self.socketPath = socketPath
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        listenFD = try UnixSocket.listen(path: socketPath)
        let fd = listenFD
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "sousbar.accept"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            UnixSocket.configureAccepted(client)
            Thread.detachNewThread { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }

        // Only accept connections from our own user.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }

        UnixSocket.setReadTimeout(client, seconds: 5)
        guard let line = UnixSocket.readLine(client), let message = Wire.decode(line) else { return }

        let expectsReply = message["expectsReply"] as? Bool ?? false
        guard expectsReply else {
            DispatchQueue.main.async { self.onMessage?(message, nil) }
            return
        }

        let box = ReplyBox()
        DispatchQueue.main.async { self.onMessage?(message, box) }

        let deadline = Date().addingTimeInterval(replyDeadline())
        while true {
            // Backstop: no answer in time (e.g. the main thread is stuck) → no decision, so
            // Claude Code shows its normal terminal prompt instead of waiting up to 10 minutes.
            if Date() >= deadline, box.finish(nil) {
                DispatchQueue.main.async { self.onTimedOut?(box) }
            }
            if box.wait(timeout: 0.4) {
                var reply: [String: Any] = ["v": 1]
                reply["output"] = box.output ?? NSNull()
                if let data = Wire.encode(reply) { UnixSocket.writeAll(client, data) }
                return
            }
            if UnixSocket.peerClosed(client) {
                if box.finish(nil) {
                    DispatchQueue.main.async { self.onCancelled?(box) }
                }
                return
            }
        }
    }
}
