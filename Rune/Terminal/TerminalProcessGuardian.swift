import Foundation
import Darwin

/// Cleanup runs outside Rune, so an app crash cannot cancel it.
nonisolated final class TerminalProcessGuardian: @unchecked Sendable {
    private static let watchArgument = "--rune-terminal-guardian"
    private static let launchArgument = "--rune-terminal-launch"
    private static let cleanupArgument = "--rune-terminal-cleanup"
    let directory: URL
    private let executable: URL
    private let process: Process
    private let lifeline: FileHandle
    private let lock = NSLock()
    private var isClosed = false

    init() throws {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
        self.executable = executable
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rune-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pipe = Pipe()
        // Only Rune owns the write end; child execs must not keep it alive.
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw POSIXError(.EIO) }
        }
        process = Process()
        process.executableURL = executable
        process.arguments = [Self.watchArgument, directory.path]
        process.standardInput = pipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        lifeline = pipe.fileHandleForWriting
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        try pipe.fileHandleForReading.close()
    }

    deinit { requestStop() }

    func launchCommand(_ command: String, shellIntegration: Bool = false) -> String {
        let launch = "exec \(Self.quote(executable.path)) \(Self.launchArgument) \(Self.quote(directory.path)) \(Self.quote(command)) \(shellIntegration ? "shell" : "command")"
        return "/bin/sh -c " + Self.quote(launch)
    }

    var root: TerminalProcessMonitor.TerminationTarget? {
        guard let root = Self.registeredRoot(in: directory), TerminalProcessMonitor.isAlive(root) else { return nil }
        return TerminalProcessMonitor.ownedRoot(pid: root.pid, owner: getpid())
    }

    var processIdentifier: pid_t { process.processIdentifier }

    var exitCode: Int? {
        if let text = try? String(contentsOf: directory.appendingPathComponent("exit"), encoding: .utf8) { return Int(text) }
        // A failed helper must become a visible failure, not an endless Running row.
        if !process.isRunning { return 125 }
        if let root = Self.registeredRoot(in: directory), !TerminalProcessMonitor.isAlive(root) { return 125 }
        return nil
    }

    func requestStop() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? lifeline.close()
    }

    func waitForCleanup() -> Bool {
        requestStop()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(50_000) }
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        if process.terminationReason == .exit && process.terminationStatus == 0 { return true }
        // If the watchdog itself failed, a fresh helper can recover the still
        // anchored session. A failed attempt must not permanently disable Stop.
        let recovery = Process()
        recovery.executableURL = executable
        recovery.arguments = [Self.cleanupArgument, directory.path]
        recovery.standardInput = FileHandle.nullDevice
        recovery.standardOutput = FileHandle.nullDevice
        recovery.standardError = FileHandle.nullDevice
        do { try recovery.run() } catch { return false }
        recovery.waitUntilExit()
        return recovery.terminationReason == .exit && recovery.terminationStatus == 0
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        if args[1] == watchArgument {
            guard args.count == 3 else { exit(64) }
            watch(directory: URL(fileURLWithPath: args[2]))
        }
        if args[1] == launchArgument {
            guard args.count == 5 else { exit(64) }
            launch(directory: URL(fileURLWithPath: args[2]), command: args[3], shellIntegration: args[4] == "shell")
        }
        if args[1] == cleanupArgument {
            guard args.count == 3 else { exit(64) }
            recover(directory: URL(fileURLWithPath: args[2]))
        }
        return false
    }

    private static func watch(directory: URL) -> Never {
        let owner = getppid()
        _ = setsid()
        for value in [SIGHUP, SIGTERM, SIGINT] { signal(value, SIG_IGN) }
        var registration: TerminalProcessMonitor.TerminationTarget?
        var sessionID: pid_t = -1
        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        while true {
            // EOF wins over registration. No user command runs without an ACK.
            let result = poll(&input, 1, registration == nil ? 10 : -1)
            if result < 0 && errno == EINTR { continue }
            if result != 0 { break }
            if registration == nil,
               let text = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
               let pid = Int32(text), let target = TerminalProcessMonitor.target(pid: pid),
               TerminalProcessMonitor.isLauncher(pid: pid, directory: directory),
               TerminalProcessMonitor.ownedRoot(pid: pid, owner: owner) != nil {
                let sid = getsid(pid)
                guard sid > 0, sid != getsid(owner) else { break }
                registration = target
                sessionID = sid
                do {
                    try JSONEncoder().encode(target).write(to: directory.appendingPathComponent("identity"), options: .atomic)
                    try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
                }
                catch { break }
            }
        }
        try? Data().write(to: directory.appendingPathComponent("cancelled"), options: .atomic)
        if let registration {
            // Keep retrying outside the app if kernel inspection temporarily fails.
            // The stopped keeper preserves session identity between attempts.
            while !TerminalProcessMonitor.cleanSession(root: registration, sessionID: sessionID, recoveryFile: directory.appendingPathComponent("survivors")) {
                sleep(1)
            }
        }
        try? FileManager.default.removeItem(at: directory)
        exit(0)
    }

    private static func launch(directory: URL, command: String, shellIntegration: Bool) -> Never {
        // The keeper stays in the terminal's session even after the shell exits.
        // This anchors session identity while background jobs are being cleaned.
        for value in [SIGHUP, SIGTERM, SIGINT, SIGTTOU] { signal(value, SIG_IGN) }
        if isatty(STDIN_FILENO) == 0 {
            // Foundation's Process starts a process-group leader. Leave that
            // group before creating a private session for a non-PTY launch.
            _ = setpgid(0, getpgid(getppid()))
            guard setsid() >= 0 else { failLaunch(directory: directory) }
        }
        // One guardian authorizes exactly one surface, even if SwiftUI recreates it.
        let registration = open(directory.appendingPathComponent("pid").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard registration >= 0 else { exit(125) }
        let pidData = Array(String(getpid()).utf8)
        let written = pidData.withUnsafeBytes { write(registration, $0.baseAddress, $0.count) }
        close(registration)
        guard written == pidData.count else { failLaunch(directory: directory) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) {
            if ProcessInfo.processInfo.systemUptime > deadline
                || !FileManager.default.fileExists(atPath: directory.path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path) { failLaunch(directory: directory) }
            usleep(10_000)
        }
        guard let identity = registeredRoot(in: directory), identity.pid == getpid(),
              TerminalProcessMonitor.isAlive(identity) else { failLaunch(directory: directory) }
        #if RUNE_GUARDIAN_TESTING
        if ProcessInfo.processInfo.environment["RUNE_GUARDIAN_PAUSE_LAUNCH"] == "1" { raise(SIGSTOP) }
        #endif
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { failLaunch(directory: directory) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for value in [SIGHUP, SIGTERM, SIGINT, SIGQUIT, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU] { sigaddset(&defaults, value) }
        var mask = sigset_t()
        sigemptyset(&mask)
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP)) == 0
        else { failLaunch(directory: directory) }
        var childEnvironment = ProcessInfo.processInfo.environment
        var command = command
        if shellIntegration, let resources = childEnvironment["GHOSTTY_RESOURCES_DIR"] {
            // The keeper hides the actual shell from Ghostty's auto-detection.
            // Use the bootstrap contract shipped in its shell-integration resources.
            let shell = childEnvironment["SHELL"] ?? "/bin/zsh"
            switch URL(fileURLWithPath: shell).lastPathComponent {
            case "zsh":
                childEnvironment["GHOSTTY_ZSH_ZDOTDIR"] = childEnvironment["ZDOTDIR"]
                childEnvironment["ZDOTDIR"] = resources + "/shell-integration/zsh"
            case "bash":
                // Apple's bash overrides POSIX startup handling and ignores ENV.
                // Preserve its login startup files instead of leaving injection
                // variables behind. Other bash builds use Ghostty's bootstrap.
                // Source: apple-oss-distributions/bash, shell.c:run_startup_files.
                if URL(fileURLWithPath: shell).resolvingSymlinksInPath().path == "/bin/bash" { break }
                childEnvironment["GHOSTTY_BASH_ENV"] = childEnvironment["ENV"]
                childEnvironment["ENV"] = resources + "/shell-integration/bash/ghostty.bash"
                childEnvironment["GHOSTTY_BASH_INJECT"] = "1"
                if childEnvironment["HISTFILE"] == nil {
                    childEnvironment["HISTFILE"] = (childEnvironment["HOME"] ?? "") + "/.bash_history"
                    childEnvironment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
                }
                command = quote(shell) + " --posix -il"
            default: break
            }
        }
        var argv: [UnsafeMutablePointer<CChar>?] = ["sh", "-c", "exec " + command].map { value in value.withCString { strdup($0) } }
        argv.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = childEnvironment.map { key, value in
            "\(key)=\(value)".withCString { strdup($0) }
        }
        environment.append(nil)
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&child, "/bin/sh", nil, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        for pointer in argv { free(pointer) }
        for pointer in environment { free(pointer) }
        posix_spawnattr_destroy(&attributes)
        guard result == 0 else { failLaunch(directory: directory) }
        if isatty(STDIN_FILENO) != 0 { _ = tcsetpgrp(STDIN_FILENO, child) }
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        try? Data(String(code).utf8).write(to: directory.appendingPathComponent("exit"), options: .atomic)
        while true { pause() }
    }

    private static func failLaunch(directory: URL) -> Never {
        try? Data("125".utf8).write(to: directory.appendingPathComponent("exit"), options: .atomic)
        exit(125)
    }

    private static func recover(directory: URL) -> Never {
        let owner = getppid()
        _ = setsid()
        for value in [SIGHUP, SIGTERM, SIGINT] { signal(value, SIG_IGN) }
        guard let root = registeredRoot(in: directory), TerminalProcessMonitor.isAlive(root),
              TerminalProcessMonitor.ownedRoot(pid: root.pid, owner: owner) != nil else {
            exit(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) ? 1 : 0)
        }
        let sid = getsid(root.pid)
        guard sid > 0, sid != getsid(owner) else { exit(1) }
        let cleaned = TerminalProcessMonitor.cleanSession(root: root, sessionID: sid, recoveryFile: directory.appendingPathComponent("survivors"))
        if cleaned { try? FileManager.default.removeItem(at: directory) }
        exit(cleaned ? 0 : 1)
    }

    private static func registeredRoot(in directory: URL) -> TerminalProcessMonitor.TerminationTarget? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("identity")) else { return nil }
        return try? JSONDecoder().decode(TerminalProcessMonitor.TerminationTarget.self, from: data)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
