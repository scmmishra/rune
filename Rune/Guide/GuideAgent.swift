import Foundation

nonisolated enum GuideAgent: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"
    var id: String { rawValue }
    var command: String { self == .codex ? "codex" : "claude" }

    var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appending(path: command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func arguments(schemaURL: URL, outputURL: URL, executableURL: URL) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let executablePath = String(decoding: try encoder.encode(executableURL.resolvingSymlinksInPath().path), as: UTF8.self)
        return switch self {
        case .codex:
            // Reuse authentication, but keep this background run independent of user MCP,
            // hooks, and permission overrides. Only repository/system reads are granted.
            // https://developers.openai.com/codex/config-reference#permissions
            ["exec", "--ignore-user-config", "--ignore-rules", "--strict-config",
             "-c", "approval_policy=\"never\"", "-c", "default_permissions=\"rune_guide\"",
             "-c", "permissions.rune_guide.filesystem={\":minimal\"=\"read\",\":workspace_roots\"=\"read\",\(executablePath)=\"read\"}",
             "-c", "permissions.rune_guide.network.enabled=false",
             "-c", "shell_environment_policy.inherit=\"none\"", "-c", "allow_login_shell=false",
             "-c", "web_search=\"disabled\"", "--ephemeral", "--color", "never", "--output-schema", schemaURL.path, "-o", outputURL.path, "-"]
        case .claude:
            // Restrict the tool set as well as permissions: plan mode alone still exposes tools.
            // https://code.claude.com/docs/en/headless
            ["-p", "--restricted", "--settings", "{\"disableAllHooks\":true}", "--output-format", "json", "--json-schema", ChangeGuide.schema,
             "--tools", "Read,Glob,Grep", "--allowedTools", "Read,Glob,Grep",
             "--permission-mode", "dontAsk", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
             "--no-session-persistence"]
        }
    }

    func decode(_ data: Data) throws -> ChangeGuide {
        if self == .codex { return try JSONDecoder().decode(ChangeGuide.self, from: data) }
        struct Response: Decodable {
            let is_error: Bool?
            let structured_output: ChangeGuide?
            let result: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.is_error != true, let guide = response.structured_output else {
            throw GuideError.message(response.result.map { String($0.prefix(600)) } ?? "Claude Code did not return a guide. Check your login and try again.")
        }
        return guide
    }
}

@MainActor
final class GuideAgentRunner {
    private var process: Process?

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // A CLI may ignore SIGTERM during a request. Bound cancellation without blocking the UI.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func generate(agent: GuideAgent, snapshot: GuideSnapshot, rootURL: URL) async throws -> ChangeGuide {
        guard let executable = agent.executable else {
            throw GuideError.message("Install \(agent.rawValue) and sign in from your terminal, then try again.")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "rune-guide-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appending(path: "prompt")
        let schemaURL = directory.appending(path: "schema.json")
        let outputURL = directory.appending(path: "guide.json")
        let logURL = directory.appending(path: "stdout")
        let errorURL = directory.appending(path: "stderr")
        try Data(snapshot.prompt.utf8).write(to: inputURL)
        try Data(ChangeGuide.schema.utf8).write(to: schemaURL)
        try Data().write(to: logURL)
        try Data().write(to: errorURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: logURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let child = Process()
        child.executableURL = executable.resolvingSymlinksInPath()
        child.arguments = try agent.arguments(schemaURL: schemaURL, outputURL: outputURL, executableURL: executable)
        child.currentDirectoryURL = rootURL
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [executable.deletingLastPathComponent().path, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        environment.removeValue(forKey: "CLAUDECODE")
        child.environment = environment
        // File-backed I/O avoids pipe-buffer deadlocks with verbose agents and large prompts.
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        try Task.checkCancellation()
        try child.run()
        process = child
        defer { process = nil }
        do {
            let deadline = ContinuousClock.now + .seconds(180)
            while child.isRunning {
                try await Task.sleep(for: .milliseconds(100))
                guard ContinuousClock.now < deadline else { throw GuideError.message("Generation timed out. Try a smaller set of changes.") }
                for url in [logURL, errorURL, outputURL] {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= 5_000_000 else { throw GuideError.message("The agent returned too much output. Try a smaller set of changes.") }
                }
            }
            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
        guard child.terminationStatus == 0 else {
            let details = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw GuideError.message("\(agent.rawValue) exited with status \(child.terminationStatus). Check that it is up to date and signed in.\n\(details.suffix(600))")
        }
        let data = try Data(contentsOf: agent == .codex ? outputURL : logURL)
        let guide = try agent.decode(data)
        try guide.validate(against: snapshot)
        return guide
    }
}
