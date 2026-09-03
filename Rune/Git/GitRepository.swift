import Foundation

nonisolated enum GitRepository {
    struct SnapshotResult: Sendable {
        let snapshot: GitSnapshot
        let errorMessage: String?
    }

    struct CommitResult: Sendable {
        let succeeded: Bool
        let errorMessage: String?
    }

    static func snapshot(at rootURL: URL) -> SnapshotResult {
        let statusResult = runGit(
            ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"],
            at: rootURL,
            readOnly: true
        )
        guard statusResult.status == 0 else {
            return SnapshotResult(snapshot: .notRepository, errorMessage: "Not a Git repository")
        }

        let stagedDiffs = diffCounts(
            from: runGit(["diff", "--cached", "--numstat", "-z", "--no-renames"], at: rootURL, readOnly: true).data
        )
        let unstagedDiffs = diffCounts(
            from: runGit(["diff", "--numstat", "-z", "--no-renames"], at: rootURL, readOnly: true).data
        )
        let parsedStatus = parseStatus(statusResult.data)
        let changes = parsedStatus.changes.map { change in
            var change = change
            change.stagedDiff = combinedDiff(for: change, in: stagedDiffs)
            change.unstagedDiff = combinedDiff(for: change, in: unstagedDiffs)
            return change
        }

        return SnapshotResult(
            snapshot: GitSnapshot(branch: parsedStatus.branch, changes: changes, isRepository: true),
            errorMessage: nil
        )
    }

    static func commitAll(message: String, at rootURL: URL) -> CommitResult {
        let addResult = runGit(["add", "--all"], at: rootURL, readOnly: false)
        guard addResult.status == 0 else {
            return CommitResult(succeeded: false, errorMessage: errorMessage(from: addResult.data))
        }

        let commitResult = runGit(["commit", "-m", message], at: rootURL, readOnly: false)
        guard commitResult.status == 0 else {
            return CommitResult(succeeded: false, errorMessage: errorMessage(from: commitResult.data))
        }
        return CommitResult(succeeded: true, errorMessage: nil)
    }

    private static func parseStatus(_ data: Data) -> (branch: String, changes: [GitChange]) {
        let records = data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        var branch = "Git"
        var changes: [GitChange] = []
        var index = 0

        if let first = records.first, first.hasPrefix("## ") {
            branch = branchName(from: first)
            index = 1
        }

        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let status = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            let isUntracked = status == ["?", "?"]
            let stagedState = isUntracked ? nil : GitFileState(code: status[0])
            let unstagedState = isUntracked ? .untracked : GitFileState(code: status[1])
            var previousPath: String?

            if status.contains("R") || status.contains("C") {
                index += 1
                if index < records.count {
                    previousPath = records[index]
                }
            }

            changes.append(
                GitChange(
                    path: path,
                    previousPath: previousPath,
                    stagedState: stagedState,
                    unstagedState: unstagedState
                )
            )
            index += 1
        }

        return (branch, changes.sorted { $0.path < $1.path })
    }

    private static func branchName(from header: String) -> String {
        let value = String(header.dropFirst(3))
        if value.hasPrefix("No commits yet on ") {
            return String(value.dropFirst("No commits yet on ".count))
        }
        if value.hasPrefix("HEAD ") {
            return "detached HEAD"
        }
        return value.components(separatedBy: "...").first?
            .components(separatedBy: " [").first ?? value
    }

    private static func diffCounts(from data: Data) -> [String: GitDiffCount] {
        var result: [String: GitDiffCount] = [:]

        for recordData in data.split(separator: 0) {
            guard let record = String(data: recordData, encoding: .utf8) else { continue }
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }

            result[String(fields[2])] = GitDiffCount(
                additions: Int(fields[0]),
                deletions: Int(fields[1])
            )
        }
        return result
    }

    private static func combinedDiff(
        for change: GitChange,
        in counts: [String: GitDiffCount]
    ) -> GitDiffCount? {
        let current = counts[change.path]
        let previous = change.previousPath.flatMap { counts[$0] }
        return GitDiffCount.combining(current, previous)
    }

    private static func runGit(
        _ arguments: [String],
        at rootURL: URL,
        readOnly: Bool
    ) -> (data: Data, status: Int32) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path] + arguments
        process.standardOutput = output
        process.standardError = output

        if readOnly {
            // Passive refreshes must not take optional index locks and generate
            // more filesystem events while the workspace is being watched.
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = environment
        }

        do {
            try process.run()
        } catch {
            return (Data(error.localizedDescription.utf8), -1)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    private static func errorMessage(from data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .suffix(3)
            .joined(separator: "\n") ?? "Git command failed"
    }
}

nonisolated struct GitSnapshot: Sendable {
    let branch: String
    let changes: [GitChange]
    let isRepository: Bool

    static let empty = GitSnapshot(branch: "Git", changes: [], isRepository: true)
    static let notRepository = GitSnapshot(branch: "Git", changes: [], isRepository: false)

    var staged: [GitChange] {
        changes.filter { $0.stagedState != nil }
    }

    var unstaged: [GitChange] {
        changes.filter { $0.unstagedState != nil }
    }

    var additions: Int {
        changes.reduce(into: 0) { total, change in
            total += change.stagedDiff?.additions ?? 0
            total += change.unstagedDiff?.additions ?? 0
        }
    }

    var deletions: Int {
        changes.reduce(into: 0) { total, change in
            total += change.stagedDiff?.deletions ?? 0
            total += change.unstagedDiff?.deletions ?? 0
        }
    }
}

nonisolated struct GitChange: Identifiable, Sendable {
    enum Area {
        case staged
        case unstaged
    }

    let path: String
    let previousPath: String?
    let stagedState: GitFileState?
    let unstagedState: GitFileState?
    var stagedDiff: GitDiffCount?
    var unstagedDiff: GitDiffCount?

    var id: String { path }
}

nonisolated enum GitFileState: Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case conflicted
    case untracked

    init?(code: Character) {
        switch code {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        case "?": self = .untracked
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .conflicted: "U"
        case .untracked: "?"
        }
    }
}

nonisolated struct GitDiffCount: Sendable {
    let additions: Int?
    let deletions: Int?

    static func combining(_ lhs: GitDiffCount?, _ rhs: GitDiffCount?) -> GitDiffCount? {
        guard lhs != nil || rhs != nil else { return nil }
        return GitDiffCount(
            additions: combine(lhs?.additions, rhs?.additions),
            deletions: combine(lhs?.deletions, rhs?.deletions)
        )
    }

    private static func combine(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}
