import Foundation

nonisolated struct AgentUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable, Identifiable {
        let title: String
        /// The label in the collapsed row, or nil to leave it out there.
        let shortTitle: String?
        /// Zero to one hundred.
        let usedPercent: Double
        let resetsAt: Date?

        var id: String { title }
    }

    let plan: String?
    let windows: [Window]
}

nonisolated enum AgentUsageError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        }
    }
}

/// Plan usage for Claude Code and Codex. Readings survive failures so the rows never blank.
@MainActor
final class AgentUsageModel: ObservableObject {
    static let agents: [TerminalAgent] = [.claude, .codex]

    @Published private(set) var readings: [TerminalAgent: AgentUsage] = [:]
    @Published private(set) var errors: [TerminalAgent: String] = [:]
    @Published private(set) var loading: Set<TerminalAgent> = []
    private var runningAgent: TerminalAgent?
    private var tasks: [TerminalAgent: Task<Void, Never>] = [:]

    /// The agent in the selected terminal, which is polled at a faster pace.
    func track(_ agent: TerminalAgent?) {
        let agent = agent.flatMap { Self.agents.contains($0) ? $0 : nil }
        guard agent != runningAgent else { return }
        runningAgent = agent
        // Restart polling so a newly running agent is read now, at its faster pace.
        stop()
        updatePolling()
    }

    func start() {
        updatePolling()
    }

    /// A user-initiated refresh retries Claude's sign-in, even after a failed read.
    func refresh() {
        stop()
        updatePolling(interactive: true)
    }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        loading.removeAll()
    }

    private func updatePolling(interactive: Bool = false) {
        for agent in Self.agents where tasks[agent] == nil {
            tasks[agent] = Task { await poll(agent, interactive: interactive) }
        }
    }

    private func poll(_ agent: TerminalAgent, interactive: Bool) async {
        var interactive = interactive
        while !Task.isCancelled {
            loading.insert(agent)
            let isInteractive = interactive
            let result: Result<AgentUsage, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try await (agent == .claude
                        ? ClaudeUsage.fetch(interactive: isInteractive)
                        : CodexUsage.read()))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            loading.remove(agent)
            switch result {
            case let .success(usage):
                readings[agent] = usage
                errors[agent] = nil
            case let .failure(failure):
                errors[agent] = failure.localizedDescription
            }
            interactive = false
            // Codex only rereads a local log. Claude calls a server, so poll it gently,
            // and more gently still while it is not running.
            let isRunning = runningAgent == agent
            let delay: Duration = agent == .claude ? .seconds(isRunning ? 180 : 600) : .seconds(isRunning ? 15 : 60)
            try? await Task.sleep(for: delay)
        }
    }
}

// MARK: - Codex

/// Codex records its plan limits in each session log, so this reads no credentials
/// and makes no network requests.
nonisolated enum CodexUsage {
    static func read() throws -> AgentUsage {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        let sessions = home.appending(path: "sessions")
        // The newest session may not have finished a turn yet, so look at a few.
        for log in newestLogs(in: sessions, limit: 8) {
            if let usage = latestUsage(in: log) { return usage }
        }
        throw AgentUsageError.unavailable("Usage appears after Codex's first reply.")
    }

    /// Logs live under sessions/YYYY/MM/DD. Walk the newest days instead of the whole tree.
    private static func newestLogs(in sessions: URL, limit: Int) -> [URL] {
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var logs: [(url: URL, modified: Date)] = []
        var days = 0
        outer: for year in children(sessions) {
            for month in children(year) {
                for day in children(month) {
                    for file in children(day) where file.pathExtension == "jsonl" {
                        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        logs.append((file, modified))
                    }
                    days += 1
                    if days >= 3, logs.count >= limit { break outer }
                }
            }
        }
        return logs.sorted { $0.modified > $1.modified }.prefix(limit).map(\.url)
    }

    private static func latestUsage(in log: URL) -> AgentUsage? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        // Rate limits arrive with every reply, so the tail of the log is enough.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let windows = ["primary", "secondary"].compactMap { key -> AgentUsage.Window? in
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue
                let resetsAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let (title, shortTitle) = titles(minutes: minutes)
                return AgentUsage.Window.current(title: title, shortTitle: shortTitle, usedPercent: used, resetsAt: resetsAt)
            }
            guard !windows.isEmpty else { continue }
            return AgentUsage(plan: plan(limits["plan_type"] as? String), windows: windows)
        }
        return nil
    }

    private static func titles(minutes: Int?) -> (String, String) {
        guard let minutes else { return ("Usage", "") }
        if minutes >= 10_080 { return ("Weekly", "wk") }
        if minutes >= 1_440 { return ("Daily", "day") }
        let hours = max(1, minutes / 60)
        return ("\(hours)-hour", "\(hours)h")
    }

    private static func plan(_ type: String?) -> String? {
        switch type {
        case nil, "": nil
        case "prolite": "Pro Lite"
        default: type?.capitalized
        }
    }
}

// MARK: - Claude

/// Claude Code does not record plan limits locally. This calls the endpoint behind
/// its `/usage` command with Claude Code's own sign-in, as CodexBar does. It is
/// undocumented, so a failure only leaves the last reading on screen.
nonisolated enum ClaudeUsage {
    static func fetch(interactive: Bool) async throws -> AgentUsage {
        if interactive { await ClaudeCredentials.shared.allowPrompt() }
        let credentials = try await ClaudeCredentials.shared.current()
        do {
            return try await fetch(with: credentials)
        } catch ClaudeUsageFailure.unauthorized {
            // Claude Code may have rotated its token since it was read. Read it once more.
            await ClaudeCredentials.shared.discard(credentials)
            let fresh = try await ClaudeCredentials.shared.current()
            guard fresh.accessToken != credentials.accessToken else {
                throw AgentUsageError.unavailable("Claude Code’s sign-in expired. Use Claude, then refresh.")
            }
            return try await fetch(with: fresh)
        }
    }

    private enum ClaudeUsageFailure: Error { case unauthorized }

    private static func fetch(with credentials: ClaudeCredentials.Credentials) async throws -> AgentUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The OAuth usage endpoint requires this beta header.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401: throw ClaudeUsageFailure.unauthorized
        case 429: throw AgentUsageError.unavailable("Claude usage is rate limited. Rune will try again shortly.")
        default: throw AgentUsageError.unavailable("Claude usage is unavailable (HTTP \(status)).")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentUsageError.unavailable("Claude returned usage Rune could not read.")
        }
        let windows: [AgentUsage.Window] = [
            ("five_hour", "Session", "5h"),
            ("seven_day", "Weekly", "wk"),
            ("seven_day_opus", "Weekly Opus", nil),
            ("seven_day_sonnet", "Weekly Sonnet", nil),
        ].compactMap { key, title, shortTitle -> AgentUsage.Window? in
            guard let window = object[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return AgentUsage.Window.current(
                title: title, shortTitle: shortTitle, usedPercent: used, resetsAt: (window["resets_at"] as? String).flatMap(date)
            )
        }
        guard !windows.isEmpty else { throw AgentUsageError.unavailable("Claude reported no plan limits.") }
        return AgentUsage(plan: credentials.plan, windows: windows)
    }

    private static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Reads Claude Code's sign-in at most once per launch and keeps it in memory only.
/// Rune reads it again only when the token stops working, and never again after a
/// failed read until the user refreshes.
actor ClaudeCredentials {
    static let shared = ClaudeCredentials()

    struct Credentials: Sendable {
        let accessToken: String
        let plan: String?
    }

    private var cached: Credentials?
    private var pending: Task<Credentials, Error>?
    private var isDenied = false

    func current() async throws -> Credentials {
        if let cached { return cached }
        if isDenied {
            throw AgentUsageError.unavailable("Rune could not read Claude Code’s sign-in. Refresh to try again.")
        }
        if let pending { return try await pending.value }
        // One read serves every window, so concurrent refreshes cannot stack prompts.
        let read = Task.detached(priority: .utility) { try Self.read() }
        pending = read
        defer { pending = nil }
        do {
            let credentials = try await read.value
            cached = credentials
            return credentials
        } catch ReadFailure.denied {
            isDenied = true
            throw AgentUsageError.unavailable("Rune could not read Claude Code’s sign-in. Refresh to try again.")
        }
    }

    func discard(_ credentials: Credentials) {
        if cached?.accessToken == credentials.accessToken { cached = nil }
    }

    func allowPrompt() {
        isDenied = false
    }

    private enum ReadFailure: Error { case denied }

    private static func read() throws -> Credentials {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        // Claude Code keeps its sign-in in this file where the Keychain is unavailable.
        if let data = try? Data(contentsOf: directory.appending(path: ".credentials.json")),
           let credentials = parse(data) {
            return credentials
        }

        // Claude Code saves and reads this item with /usr/bin/security, so the item
        // trusts that tool and not Rune. Reading through it needs no Keychain prompt,
        // whereas SecItemCopyMatching asked on every launch: dev builds change Rune's
        // signature, and Claude Code recreates the item whenever it refreshes sign-in.
        let security = Process()
        security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        security.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", "Claude Code-credentials"]
        let output = Pipe()
        security.standardOutput = output
        security.standardError = FileHandle.nullDevice
        do { try security.run() } catch {
            throw AgentUsageError.unavailable("Could not read Claude Code’s sign-in.")
        }
        // A prompt would block this read. Give up rather than wait on it.
        let timeout = DispatchWorkItem { security.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        security.waitUntilExit()
        timeout.cancel()

        switch security.terminationStatus {
        case 0:
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // `security -w` prints binary values as hex; Claude Code's JSON normally prints as is.
            guard let credentials = parse(Data(text.utf8)) ?? hexData(text).flatMap(parse) else {
                throw AgentUsageError.unavailable("Sign in to Claude Code to see plan usage.")
            }
            return credentials
        case 44: // errSecItemNotFound
            throw AgentUsageError.unavailable("Sign in to Claude Code to see plan usage.")
        default:
            throw ReadFailure.denied
        }
    }

    private static func hexData(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return Credentials(
            accessToken: token,
            plan: plan(subscription: oauth["subscriptionType"] as? String, tier: oauth["rateLimitTier"] as? String)
        )
    }

    private static func plan(subscription: String?, tier: String?) -> String? {
        let tier = tier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.capitalized
    }
}

extension AgentUsage.Window {
    /// A reading taken before its window reset no longer describes the current window.
    nonisolated static func current(title: String, shortTitle: String?, usedPercent: Double, resetsAt: Date?) -> Self {
        if let resetsAt, resetsAt < .now {
            return Self(title: title, shortTitle: shortTitle, usedPercent: 0, resetsAt: nil)
        }
        return Self(title: title, shortTitle: shortTitle, usedPercent: min(100, max(0, usedPercent)), resetsAt: resetsAt)
    }
}
