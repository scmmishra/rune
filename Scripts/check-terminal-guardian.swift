import Foundation
import Darwin

@main
struct TerminalGuardianChecks {
    static func main() throws {
        if TerminalProcessGuardian.runIfRequested() { return }
        if CommandLine.arguments.dropFirst().first == "--fixture" {
            try fixture(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rune-guardian-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["60"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }

        for mode in ["close", "crash", "force-quit", "startup-crash"] {
            let runDirectory = directory.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let parent = Process()
            let input = Pipe()
            parent.executableURL = Bundle.main.executableURL!
            parent.arguments = ["--fixture", runDirectory.path]
            parent.standardInput = input
            parent.standardOutput = FileHandle.nullDevice
            parent.standardError = FileHandle.standardError
            try parent.run()
            if mode == "startup-crash" {
                var target: TerminalProcessMonitor.TerminationTarget?
                for _ in 0..<100 {
                    if let text = try? String(contentsOf: runDirectory.appendingPathComponent("keeper"), encoding: .utf8),
                       let pid = Int32(text) { target = TerminalProcessMonitor.target(pid: pid); break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                precondition(target != nil)
                kill(parent.processIdentifier, SIGKILL)
                parent.waitUntilExit()
                for _ in 0..<100 {
                    if !TerminalProcessMonitor.isAlive(target!) { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                precondition(!TerminalProcessMonitor.isAlive(target!))
                precondition(!FileManager.default.fileExists(atPath: runDirectory.appendingPathComponent("root").path))
                print("Guardian startup crash: stopped launcher cleaned before user code runs.")
                continue
            }
            var targets: [TerminalProcessMonitor.TerminationTarget] = []
            for _ in 0..<100 {
                targets = ["root", "child", "orphan"].compactMap { name in
                    guard let text = try? String(contentsOf: runDirectory.appendingPathComponent(name), encoding: .utf8),
                          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                    return TerminalProcessMonitor.target(pid: pid)
                }
                if targets.count == 3 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            precondition(targets.count == 3, "Fixture must create a shell, child, and reparented background process")
            if mode == "close" { try input.fileHandleForWriting.close() }
            else { kill(parent.processIdentifier, mode == "crash" ? SIGABRT : SIGKILL) }
            parent.waitUntilExit()
            for _ in 0..<120 {
                if targets.allSatisfy({ !TerminalProcessMonitor.isAlive($0) }) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            precondition(targets.allSatisfy { !TerminalProcessMonitor.isAlive($0) }, "\(mode) left a process running")
            precondition(unrelated.isRunning, "Cleanup must not touch unrelated processes")
            print("Guardian \(mode): shell, signal-resistant child, and orphan cleaned; unrelated process preserved.")
        }
        for shell in ["/bin/zsh", "/bin/bash"] {
            let guardian = try TerminalProcessGuardian()
            let output = directory.appendingPathComponent(URL(fileURLWithPath: shell).lastPathComponent + ".log")
            let terminal = Process()
            let input = Pipe()
            terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            terminal.arguments = ["-q", "-F", output.path, "/bin/sh", "-c", guardian.launchCommand(shell + " -l", shellIntegration: true)]
            var environment = ProcessInfo.processInfo.environment
            environment["SHELL"] = shell
            environment["GHOSTTY_RESOURCES_DIR"] = FileManager.default.currentDirectoryPath + "/DerivedData/SourcePackages/checkouts/libghostty-spm/Sources/GhosttyTerminal/Resources/Ghostty"
            environment["GHOSTTY_SHELL_FEATURES"] = "cursor,title"
            terminal.environment = environment
            terminal.standardInput = input
            terminal.standardOutput = FileHandle.nullDevice
            terminal.standardError = FileHandle.nullDevice
            try terminal.run()
            Thread.sleep(forTimeInterval: 1)
            try input.fileHandleForWriting.write(contentsOf: Data("cd /; printf 'guardian-shell-ok\\n'\n".utf8))
            var transcript = ""
            for _ in 0..<100 {
                transcript = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                if shell == "/bin/bash", transcript.contains("\r\nguardian-shell-ok\r\n") { break }
                if transcript.contains("\u{1b}]7;file://") && transcript.contains("\u{1b}]133;") { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let cleaned = guardian.waitForCleanup()
            terminal.waitUntilExit()
            precondition(cleaned)
            if shell == "/bin/bash" {
                precondition(transcript.contains("\r\nguardian-shell-ok\r\n"))
                print("Guardian Apple bash: interactive command and cleanup passed.")
                continue
            }
            precondition(transcript.contains("\u{1b}]7;file://"), "\(shell) must report its directory")
            precondition(transcript.contains("\u{1b}]133;"), "\(shell) must report shell prompts")
            print("Guardian \(shell): real PTY directory and prompt integration passed.")
        }
        let guardian = try TerminalProcessGuardian()
        let first = launch(guardian.launchCommand("/bin/sleep 60"))
        defer { guardian.requestStop(); first.waitUntilExit() }
        for _ in 0..<100 {
            if guardian.root != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let target = guardian.root!
        let duplicate = launch(guardian.launchCommand("/bin/sleep 60"))
        duplicate.waitUntilExit()
        precondition(duplicate.terminationStatus == 125, "A guardian must never authorize a second surface")
        kill(guardian.processIdentifier, SIGKILL)
        precondition(guardian.waitForCleanup(), "Stop must recover from a failed watchdog")
        precondition(!TerminalProcessMonitor.isAlive(target))
        print("Guardian duplicate launch rejected; watchdog failure recovered.")
    }

    private static func launch(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        try! process.run()
        return process
    }

    private static func fixture(directory: URL) throws {
        let guardian = try TerminalProcessGuardian()
        var environment = ProcessInfo.processInfo.environment
        environment["RUNE_TEST_DIR"] = directory.path
        if directory.lastPathComponent == "startup-crash" { environment["RUNE_GUARDIAN_PAUSE_LAUNCH"] = "1" }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.environment = environment
        let script = #"""
        trap '' HUP TERM
        /bin/sh -c 'trap "" HUP TERM; echo $$ > "$RUNE_TEST_DIR/child"; while :; do sleep 1; done' &
        /bin/sh -c '/usr/bin/nohup /bin/sh -c '\''trap "" HUP TERM; echo $$ > "$RUNE_TEST_DIR/orphan"; while :; do sleep 1; done'\'' >/dev/null 2>&1 &'
        echo $$ > "$RUNE_TEST_DIR/root"
        wait
        """#
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        shell.arguments = ["-c", guardian.launchCommand("/bin/sh -c " + quoted)]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        if directory.lastPathComponent == "startup-crash" {
            for _ in 0..<100 {
                if let target = guardian.root {
                    try Data(String(target.pid).utf8).write(to: directory.appendingPathComponent("keeper"))
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        withExtendedLifetime(guardian) {
            var byte: UInt8 = 0
            while read(STDIN_FILENO, &byte, 1) > 0 {}
        }
    }
}
