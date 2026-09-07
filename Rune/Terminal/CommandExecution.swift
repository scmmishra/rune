import Foundation

nonisolated final class CommandExecution: Sendable {
    let directory: URL
    let script: String
    let launchCommand: String

    init(command: String, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rune-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        // The exec API retains output but exposes no child exit code. A private
        // status file records the actual shell result, including `exit` and syntax errors.
        // Source: libghostty-spm 1.5.2 TerminalSurfaceOptions.waitAfterCommand.
        script = """
        printf '%s' "$$" > \(Self.quote(directory.appendingPathComponent("pid").path))
        \(Self.quote(shell)) -lic \(Self.quote(command))
        rune_exit_code=$?
        printf '%s' "$rune_exit_code" > \(Self.quote(directory.appendingPathComponent("exit").path))
        exit "$rune_exit_code"
        """
        launchCommand = "/bin/sh -c " + Self.quote(script)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func snapshot() -> (root: TerminalProcessMonitor.TerminationTarget?, exitCode: Int?) {
        let pid = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        let exit = try? String(contentsOf: directory.appendingPathComponent("exit"), encoding: .utf8)
        let root = pid.flatMap(Int32.init).flatMap { TerminalProcessMonitor.commandRoot(pid: $0, script: script) }
        return (root, exit.flatMap(Int.init))
    }
}
