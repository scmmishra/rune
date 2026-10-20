import Foundation

/// Registers `Rune --rune-mcp` with the agent CLIs, at user scope. Rune does this only when
/// asked, from the palette or the welcome window, since it edits the agents' own config files.
nonisolated enum AgentConnection {
    static let serverName = "rune"

    enum Client: String, CaseIterable, Identifiable, Sendable {
        case claude, codex
        var id: Self { self }

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            }
        }

        fileprivate func commands(executable: String) -> [[String]] {
            let add = ["--", executable, "--rune-mcp"]
            return switch self {
            // Remove first: `add` refuses a name that is already taken.
            case .claude: [["mcp", "remove", "-s", "user", serverName], ["mcp", "add", "-s", "user", serverName] + add]
            case .codex: [["mcp", "remove", serverName], ["mcp", "add", serverName] + add]
            }
        }
    }

    enum Status: Equatable, Sendable {
        /// The CLI is not on the login shell's PATH.
        case missing
        case notConnected
        /// Connected to this Rune's binary.
        case connected
        /// Connected to another binary, such as Rune Dev's or a moved app's.
        case connectedElsewhere(String)
    }

    /// This binary, which serves as the MCP server.
    static var executable: String { Bundle.main.executableURL?.path ?? "/Applications/Rune.app/Contents/MacOS/Rune" }

    /// Reads the CLI's config file rather than running it: `claude mcp get` also starts the
    /// server to check its health, which takes seconds. Call off the main thread.
    static func status(of client: Client) -> Status {
        guard path(of: client) != nil else { return .missing }
        guard let command = registeredCommand(for: client) else { return .notConnected }
        return command == executable ? .connected : .connectedElsewhere(command)
    }

    /// Registers this binary with the client. Returns an error message, or nil.
    static func connect(_ client: Client) -> String? {
        guard let cli = path(of: client) else { return "\(client.name) is not installed." }
        let steps = client.commands(executable: executable)
        for (index, arguments) in steps.enumerated() {
            let (status, errors) = run(cli, arguments)
            // A failed remove means nothing was registered yet.
            if status != 0, index == steps.count - 1 {
                return errors.isEmpty ? "\(client.name) could not add the server." : errors
            }
        }
        return nil
    }

    private static func path(of client: Client) -> String? {
        LoginEnvironment.path.split(separator: ":")
            .map { "\($0)/\(client.rawValue)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func registeredCommand(for client: Client) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch client {
        case .claude:
            let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home
            guard let data = try? Data(contentsOf: directory.appending(path: ".claude.json")),
                  let config = try? JSONValue(json: data) else { return nil }
            return config["mcpServers"]?[serverName]?["command"]?.string
        case .codex:
            let directory = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".codex")
            guard let text = try? String(contentsOf: directory.appending(path: "config.toml"), encoding: .utf8) else { return nil }
            // A line scan of one table. Codex's config holds more TOML than Rune's parser reads.
            var inTable = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inTable = line == "[mcp_servers.\(serverName)]"; continue }
                guard inTable, line.hasPrefix("command"), let equals = line.firstIndex(of: "=") else { continue }
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                return value.count >= 2 ? String(value.dropFirst().dropLast()) : nil
            }
            return nil
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Both CLIs are often Node scripts that find `node` on PATH.
        environment["PATH"] = LoginEnvironment.path
        process.environment = environment
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        guard (try? process.run()) != nil else { return (-1, "Could not run \(executable).") }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The connection state of every client, for the welcome step and the palette.
@MainActor
final class AgentConnectionModel: ObservableObject {
    @Published private(set) var statuses: [AgentConnection.Client: AgentConnection.Status] = [:]
    @Published private(set) var isConnecting = false
    @Published private(set) var errors: [String] = []

    var canConnect: Bool {
        AgentConnection.Client.allCases.contains { client in
            switch statuses[client] {
            case .notConnected, .connectedElsewhere: true
            default: false
            }
        }
    }

    func refresh() async {
        statuses = await Task.detached {
            Dictionary(uniqueKeysWithValues: AgentConnection.Client.allCases.map { ($0, AgentConnection.status(of: $0)) })
        }.value
    }

    /// Connects every installed client that is not connected to this Rune yet.
    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        let clients = AgentConnection.Client.allCases.filter { statuses[$0] != .missing && statuses[$0] != .connected }
        errors = await Task.detached {
            clients.compactMap { client in AgentConnection.connect(client).map { "\(client.name): \($0)" } }
        }.value
        isConnecting = false
        await refresh()
    }
}
