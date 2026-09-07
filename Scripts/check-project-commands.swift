import Foundation

@main
struct ProjectCommandChecks {
    static func main() throws {
        if TerminalProcessGuardian.runIfRequested() { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rune-command-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = """
        # Local services
        web: PORT=3000 bundle exec rails server
        worker: echo 'https://example.com:3000/#hello' | cat
        invalid entry
        web: duplicate
        empty:
        test: printf 'hello world'
        """
        let procfileURL = root.appendingPathComponent("Procfile.dev")
        let parsed = Procfile.parse(text, url: procfileURL)
        precondition(parsed.commands.map(\.name) == ["web", "worker", "test"])
        precondition(parsed.commands[1].command == "echo 'https://example.com:3000/#hello' | cat")
        precondition(parsed.warnings.count == 3)
        precondition(Procfile.parse("\u{FEFF}web: echo ok\r\n#comment\r\nworker: sleep 2\r\n", url: procfileURL).commands.count == 2)
        try text.write(to: procfileURL, atomically: true, encoding: .utf8)
        try "test: true".write(to: root.appendingPathComponent("Procfile.devs"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Procfile.directory"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try text.write(to: root.appendingPathComponent("nested/Procfile"), atomically: true, encoding: .utf8)
        let discovered = try Procfile.discover(in: root)
        precondition(discovered.map { $0.url.lastPathComponent } == ["Procfile.dev", "Procfile.devs"])

        let storage = ProjectCommandStorage(root: root, baseDirectory: root.appendingPathComponent("storage"))
        let empty = try storage.load()
        precondition(empty.isEmpty)
        var commands = parsed.commands
        commands[0].autoStart = true
        commands[0].workingDirectory = "nested"
        try storage.save(commands)
        let restored = try storage.load()
        precondition(restored == commands)
        precondition(commands[0].directory(relativeTo: root).path == root.appendingPathComponent("nested").path)
        precondition(ProjectCommandStorage(root: root.appendingPathComponent("nested"), baseDirectory: root).fileURL != storage.fileURL)
        try Data("invalid json".utf8).write(to: storage.fileURL)
        do { _ = try storage.load(); preconditionFailure("Corrupt storage must not silently load as empty") }
        catch is DecodingError {}
        try storage.resetKeepingBackup()
        let reset = try storage.load()
        precondition(reset.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: storage.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        precondition(backups.contains { $0.lastPathComponent.contains(".backup-") })

        for (command, expected) in [
            ("printf '%s\\n' \"it's fine: $((2+3))\" | cat\nexit 7", 7),
            ("true", 0),
            ("if then", 2)
        ] {
            let execution = try CommandExecution(command: command, shell: "/bin/bash")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", execution.script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(execution.snapshot().exitCode == expected, "Command must preserve its shell exit code")
        }

        let execution = try CommandExecution(command: "trap '' TERM; while :; do sleep 1; done", shell: "/bin/bash")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Match Ghostty's extra shell so the test exercises ancestor association.
        process.arguments = ["-c", execution.launchCommand + "\nrune_result=$?; exit \"$rune_result\""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var target: TerminalProcessMonitor.TerminationTarget?
        for _ in 0..<100 {
            target = execution.snapshot().root
            if target != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let target else { process.terminate(); preconditionFailure("Launch wrapper must be identifiable") }
        precondition(TerminalProcessMonitor.commandRoot(pid: target.pid, script: "unrelated command") == nil)
        Thread.sleep(forTimeInterval: 0.1)
        let targets = TerminalProcessMonitor.beginTermination(root: target)
        precondition(targets.count >= 2, "Stop must include child commands")
        Thread.sleep(forTimeInterval: 0.1)
        TerminalProcessMonitor.forceTermination(targets)
        process.waitUntilExit()
        precondition(execution.snapshot().root == nil)
        print("Project command checks passed: Procfile parsing/discovery, storage, shell quoting, exit codes, and process termination.")
    }
}
