import Foundation
import Synchronization

nonisolated struct ProjectSearchMatch: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    /// One-based line number.
    let line: Int
    /// The match in the file's UTF-16 text, ready for NSTextView selection.
    let range: NSRange
    let before: String
    let match: String
    let after: String

    var id: String { relativePath + ":" + String(range.location) }
}

nonisolated struct ProjectSearchFile: Identifiable, Sendable {
    let url: URL
    let relativePath: String
    let matches: [ProjectSearchMatch]

    var id: String { relativePath }
}

@MainActor
final class ProjectSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var files: [ProjectSearchFile] = []
    @Published private(set) var matches: [ProjectSearchMatch] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isTruncated = false
    @Published var selection: ProjectSearchMatch.ID?
    private var task: Task<Void, Never>?

    static let resultLimit = 2000

    /// Keeps the current results on screen until the new ones arrive, so a
    /// refresh never flashes an empty list.
    func search(in index: [WorkspaceFileIndex.Entry], debounce: Bool = true) {
        task?.cancel()
        let query = query
        guard !query.isEmpty else {
            files = []
            matches = []
            isSearching = false
            isTruncated = false
            selection = nil
            return
        }

        isSearching = true
        task = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let worker = Task.detached(priority: .userInitiated) {
                await ProjectSearch.run(query: query, files: index, limit: Self.resultLimit)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            files = result.files
            matches = result.files.flatMap(\.matches)
            isTruncated = result.isTruncated
            isSearching = false
            if !matches.contains(where: { $0.id == selection }) { selection = matches.first?.id }
        }
    }

    func cancel() {
        task?.cancel()
        isSearching = false
    }
}

nonisolated enum ProjectSearch {
    /// Mirrors the file preview, which does not open larger files.
    static let maxFileSize = 5_000_000

    static func run(
        query: String,
        files: [WorkspaceFileIndex.Entry],
        limit: Int
    ) async -> (files: [ProjectSearchFile], isTruncated: Bool) {
        let budget = MatchBudget(limit)
        let workers = max(1, min(files.count, ProcessInfo.processInfo.activeProcessorCount))
        let found = await withTaskGroup(of: [ProjectSearchFile].self) { group in
            for worker in 0..<workers {
                // Stride rather than slice so large directories spread across workers.
                group.addTask {
                    var results: [ProjectSearchFile] = []
                    for index in stride(from: worker, to: files.count, by: workers) {
                        guard !Task.isCancelled, !budget.isExhausted else { break }
                        let file = files[index]
                        let matches = search(query, in: file, budget: budget)
                        if !matches.isEmpty {
                            results.append(ProjectSearchFile(url: file.url, relativePath: file.relativePath, matches: matches))
                        }
                    }
                    return results
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        return (found.sorted { $0.relativePath < $1.relativePath }, budget.isExhausted)
    }

    private static func search(_ query: String, in file: WorkspaceFileIndex.Entry, budget: MatchBudget) -> [ProjectSearchMatch] {
        guard let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxFileSize,
              let data = try? Data(contentsOf: file.url, options: [.mappedIfSafe]),
              // A NUL byte near the start is how Git and grep recognize binary files.
              !data.prefix(8192).contains(0),
              let text = NSString(data: data, encoding: String.Encoding.utf8.rawValue)
        else { return [] }

        var matches: [ProjectSearchMatch] = []
        var searchStart = 0
        var line = 1
        var lineCountedTo = 0
        var characters: [unichar] = []

        while searchStart < text.length {
            let found = text.range(
                of: query, options: [.caseInsensitive, .literal],
                range: NSRange(location: searchStart, length: text.length - searchStart)
            )
            guard found.location != NSNotFound, found.length > 0, budget.take() else { break }

            // Copy the UTF-16 buffer once, only for files that match, to count lines cheaply.
            if characters.isEmpty {
                characters = [unichar](repeating: 0, count: text.length)
                text.getCharacters(&characters, range: NSRange(location: 0, length: text.length))
            }
            for index in lineCountedTo..<found.location where characters[index] == 0x0A { line += 1 }
            lineCountedTo = found.location

            let lineRange = text.lineRange(for: found)
            let before = text.substring(with: NSRange(location: lineRange.location, length: found.location - lineRange.location))
            let after = text.substring(with: NSRange(location: NSMaxRange(found), length: NSMaxRange(lineRange) - NSMaxRange(found)))
            let leading = before.drop { $0.isWhitespace }
            matches.append(ProjectSearchMatch(
                url: file.url,
                relativePath: file.relativePath,
                line: line,
                range: found,
                before: leading.count > 48 ? "…" + leading.suffix(48) : String(leading),
                match: text.substring(with: found),
                after: String(after.trimmingCharacters(in: .newlines).prefix(160))
            ))
            searchStart = NSMaxRange(found)
        }
        return matches
    }
}

/// Shared across search workers so a broad query stops reading files once the
/// result limit is reached, instead of collecting every match in the project.
nonisolated private final class MatchBudget: Sendable {
    private let remaining: Mutex<Int>

    init(_ limit: Int) { remaining = Mutex(limit) }

    var isExhausted: Bool { remaining.withLock { $0 <= 0 } }

    func take() -> Bool {
        remaining.withLock { value in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
    }
}
