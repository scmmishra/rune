import CryptoKit
import Foundation

/// One agent conversation that can be picked up again, found by a key such as a
/// conversation ID or a branch.
nonisolated enum AgentThread {
    /// The agents that can reopen a conversation from a key.
    enum Agent: String, CaseIterable, Sendable {
        case claude, clue
    }

    /// What an item asks for: the thread for `key`, resumed if it exists.
    struct Request: Equatable, Sendable {
        let key: String
        var agent = Agent.claude
        /// The tab's name, and the thread's name in Claude Code's own picker. Clue names
        /// the session after the key.
        var name: String?
        /// What a new thread starts with. A resumed thread already has its history.
        var prompt: String?
        /// The model and effort the agent runs with, each time the thread is opened.
        /// Nil leaves the agent's own setting alone.
        var model: String?
        var effort: String?

        static let efforts = ["low", "medium", "high", "xhigh", "max"]
    }

    /// The command that opens the thread in a terminal.
    static func command(for request: Request, in root: URL) -> String {
        // Every value is one quoted argument: text from a card never reaches the shell as code.
        var settings = ""
        if let model = request.model, !model.isEmpty { settings += " --model \(CommandExecution.quote(model))" }
        if let effort = request.effort, !effort.isEmpty { settings += " --effort \(CommandExecution.quote(effort))" }

        switch request.agent {
        case .claude: return claudeCommand(for: request, settings: settings, in: root)
        case .clue: return clueCommand(for: request, settings: settings)
        }
    }

    /// Resumes the session recorded for the key, or starts one and records it. Claude Code
    /// can start a session under an ID chosen ahead of time, which lets a key find it again.
    private static func claudeCommand(for request: Request, settings: String, in root: URL) -> String {
        var threads = load(for: root)
        if let id = threads[request.key], hasTranscript(id, in: root) {
            return "claude --resume \(CommandExecution.quote(id))" + settings
        }
        // Lowercased, as Claude Code writes session IDs.
        let id = UUID().uuidString.lowercased()
        threads[request.key] = id
        save(threads, for: root)
        var command = "claude --session-id \(CommandExecution.quote(id))" + settings
        if let name = request.name, !name.isEmpty { command += " --name \(CommandExecution.quote(name))" }
        if let prompt = request.prompt, !prompt.isEmpty { command += " \(CommandExecution.quote(prompt))" }
        return command
    }

    /// Clue opens the session with this name in the folder, or creates it, and sends the
    /// prompt only when it creates it. So Rune runs the same command every time and keeps
    /// no record. The `--` keeps a prompt that starts with a dash from reading as a flag.
    private static func clueCommand(for request: Request, settings: String) -> String {
        var command = "clue --name \(CommandExecution.quote(clueName(for: request.key)))" + settings
        if let prompt = request.prompt, !prompt.isEmpty { command += " -- \(CommandExecution.quote(prompt))" }
        return command
    }

    /// A session name for the key. Clue allows letters, digits, `.`, `_` and `-`, up to 64
    /// characters, and ignores case. A key outside that gets a hash, so two keys never share a name.
    static func clueName(for key: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        if key.count <= 64, key.first != "-", key.allSatisfy(allowed.contains) { return key }
        let slug = key.lowercased().map { allowed.contains($0) ? $0 : "-" }.drop { $0 == "-" }.prefix(55)
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return (slug.isEmpty ? "thread" : String(slug)) + "-" + hash
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
