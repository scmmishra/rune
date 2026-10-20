import AppKit
import Darwin

/// Lets an agent running in one of Rune's terminals act on the window around it, through
/// `Rune --rune-mcp`. Each Rune process listens on one socket. A request comes from the
/// MCP server, a descendant of the agent, so Rune knows the caller by its process ancestry.
/// That ancestry picks the window and the pane, and nothing outside Rune's terminals gets in.
nonisolated enum RuneControl {
    /// One socket per Rune process, named by its process ID. The MCP server finds its Rune
    /// by looking for the socket of one of its own ancestors.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".rune/run")
    }

    static func socketPath(for pid: pid_t) -> String {
        directory.appending(path: "\(pid).sock").path
    }

    /// A request is one line of JSON and a reply ends the connection. Both stay small.
    static let maximumMessageSize = 1 << 20

    /// The process and its parents, nearest first. Stops at launchd.
    static func ancestry(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while current > 1, chain.count < 64 {
            chain.append(current)
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
                  size == MemoryLayout<kinfo_proc>.stride else { break }
            current = info.kp_eproc.e_ppid
        }
        return chain
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// Reads until the peer closes or sends a newline.
    static func readMessage(from descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < maximumMessageSize {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if buffer.prefix(count).contains(UInt8(ascii: "\n")) { break }
        }
        return data.isEmpty ? nil : data
    }

    static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

/// What a window answers: text for the agent, and whether the request failed.
struct RuneControlReply: Sendable {
    let text: String
    var isError = false

    static func failure(_ text: String) -> RuneControlReply { RuneControlReply(text: text, isError: true) }
}

/// One window's part in the control socket. It claims requests from its own terminals.
@MainActor
final class RuneControlTarget {
    let terminals: TerminalSessions
    let handle: (_ tool: String, _ arguments: [String: JSONValue], _ caller: TerminalSession) -> RuneControlReply

    init(terminals: TerminalSessions,
         handle: @escaping (_ tool: String, _ arguments: [String: JSONValue], _ caller: TerminalSession) -> RuneControlReply) {
        self.terminals = terminals
        self.handle = handle
    }

    /// The terminal whose process tree contains the caller, if it is one of this window's.
    func caller(in ancestry: Set<pid_t>) -> TerminalSession? {
        terminals.all.first { session in
            guard let root = session.rootProcess?.pid else { return false }
            return ancestry.contains(root)
        }
    }
}

@MainActor
final class RuneControlServer {
    static let shared = RuneControlServer()

    private var targets: [ObjectIdentifier: RuneControlTarget] = [:]
    private var listener: DispatchSourceRead?
    private nonisolated let queue = DispatchQueue(label: "rune.control", attributes: .concurrent)

    func register(_ target: RuneControlTarget) {
        targets[ObjectIdentifier(target)] = target
        startIfNeeded()
    }

    func unregister(_ target: RuneControlTarget) {
        targets.removeValue(forKey: ObjectIdentifier(target))
    }

    private func startIfNeeded() {
        guard listener == nil else { return }
        let path = RuneControl.socketPath(for: getpid())
        let directory = RuneControl.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        Self.removeStaleSockets(in: directory)
        guard var address = RuneControl.makeAddress(path) else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        // Terminals are children of Rune. Without this, every shell would hold the socket open.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            return
        }
        listener = Self.makeListener(on: descriptor, queue: queue)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { _ in unlink(path) }
    }

    /// Nonisolated, so the handler is too: it runs on the control queue, and a handler
    /// made on the main actor would trap there.
    private nonisolated static func makeListener(on descriptor: Int32, queue: DispatchQueue) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { accept(on: descriptor) }
        source.resume()
        return source
    }

    /// A crashed Rune leaves its socket behind. Remove those of processes that are gone.
    private nonisolated static func removeStaleSockets(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".sock") {
            guard let pid = pid_t(name.dropLast(5)), kill(pid, 0) != 0, errno == ESRCH else { continue }
            unlink(directory.appending(path: name).path)
        }
    }

    private nonisolated static func accept(on listener: Int32) {
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return }
        _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer > 0,
              let data = RuneControl.readMessage(from: connection),
              let request = try? JSONValue(json: data), let tool = request["tool"]?.string else {
            close(connection)
            return
        }
        let arguments = request["arguments"]?.object ?? [:]
        // Read the ancestry now: the caller may exit before the main thread gets to it.
        let ancestry = Set(RuneControl.ancestry(of: peer))
        Task { @MainActor in
            let reply = RuneControlServer.shared.handle(tool: tool, arguments: arguments, ancestry: ancestry)
            let object: [String: Any] = ["text": reply.text, "isError": reply.isError]
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(UInt8(ascii: "\n"))
            RuneControl.writeAll(data, to: connection)
            close(connection)
        }
    }

    private func handle(tool: String, arguments: [String: JSONValue], ancestry: Set<pid_t>) -> RuneControlReply {
        for target in targets.values {
            if let caller = target.caller(in: ancestry) { return target.handle(tool, arguments, caller) }
        }
        return .failure("This process does not run in a Rune terminal.")
    }
}
