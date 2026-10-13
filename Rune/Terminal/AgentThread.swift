import Foundation

/// One agent conversation that can be picked up again, found by a key such as a
/// conversation ID or a branch.
nonisolated enum AgentThread {
    /// What an item asks for: the thread for `key`, resumed if it exists.
    struct Request: Equatable, Sendable {
        let key: String
        /// The tab's name, and the thread's name in the agent's own picker.
        var name: String?
        /// What a new thread starts with. A resumed thread already has its history.
        var prompt: String?
        /// The model and effort the agent runs with, each time the thread is opened.
        /// Nil leaves the agent's own setting alone.
        var model: String?
        var effort: String?

        static let efforts = ["low", "medium", "high", "xhigh", "max"]
    }

    /// Threads are Claude Code sessions for now: it is the agent that can start a session
    /// under an ID chosen ahead of time, which is what lets a key find its thread again.
    private static let agent = "claude"

    /// The command that opens the thread in a terminal: resuming the one recorded for the
    /// key, or starting a new one and recording it.
    static func command(for request: Request, in root: URL) -> String {
        // Every value is one quoted argument: text from a card never reaches the shell as code.
        var settings = ""
        if let model = request.model, !model.isEmpty { settings += " --model \(CommandExecution.quote(model))" }
        if let effort = request.effort, !effort.isEmpty { settings += " --effort \(CommandExecution.quote(effort))" }

        var threads = load(for: root)
        if let id = threads[request.key], hasTranscript(id, in: root) {
            return "\(agent) --resume \(CommandExecution.quote(id))" + settings
        }
        // Lowercased, as Claude Code writes session IDs.
        let id = UUID().uuidString.lowercased()
        threads[request.key] = id
        save(threads, for: root)
        var command = "\(agent) --session-id \(CommandExecution.quote(id))" + settings
        if let name = request.name, !name.isEmpty { command += " --name \(CommandExecution.quote(name))" }
        if let prompt = request.prompt, !prompt.isEmpty { command += " \(CommandExecution.quote(prompt))" }
        return command
    }

    /// `~/.rune/threads/<folder>-<hash>.json`, holding the session ID of each key.
    private static func file(for root: URL) -> URL {
        WorkspaceLayoutStore.homeFile(for: root, in: "threads")
    }

    private static func load(for root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file(for: root)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save(_ threads: [String: String], for root: URL) {
        let file = file(for: root)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(threads).write(to: file, options: .atomic)
    }

    /// Whether Claude Code still has the session. It keeps each one under
    /// `~/.claude/projects/<folder path with every other character as a dash>/<id>.jsonl`.
    /// Resuming a session it has dropped fails, so that key starts a new thread instead.
    private static func hasTranscript(_ id: String, in root: URL) -> Bool {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        let folder = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let transcript = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects/\(folder)/\(id).jsonl")
        return FileManager.default.fileExists(atPath: transcript.path)
    }
}
