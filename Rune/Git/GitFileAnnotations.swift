import Foundation

/// How an editor buffer differs from HEAD's copy of the file.
nonisolated struct GitLineChanges: Sendable, Equatable {
    enum Kind: Sendable { case added, modified }

    /// One zero-context hunk. A start is the first line the hunk covers, or the
    /// line it sits before when its count is zero.
    struct Hunk: Sendable, Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    let hunks: [Hunk]
    /// Buffer lines that are new or changed, keyed by one-based line number.
    let kinds: [Int: Kind]
    /// Buffer lines that removed lines used to follow. Zero is the top of the file.
    let deletedAfter: Set<Int>

    /// Parses the hunk headers of a `git diff -U0`.
    init(diff: String) {
        var hunks: [Hunk] = []
        var kinds: [Int: Kind] = [:]
        var deletedAfter: Set<Int> = []
        for line in diff.split(separator: "\n") where line.hasPrefix("@@ -") {
            let line = String(line) as NSString
            guard let match = Self.header.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { continue }
            func number(_ group: Int) -> Int {
                let range = match.range(at: group)
                return range.location == NSNotFound ? 1 : Int(line.substring(with: range)) ?? 1
            }
            let oldCount = number(2), newCount = number(4)
            // An empty side names the line before the gap, not the first line of the hunk.
            let oldStart = number(1) + (oldCount == 0 ? 1 : 0)
            let newStart = number(3) + (newCount == 0 ? 1 : 0)
            hunks.append(Hunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount))
            if newCount == 0 {
                deletedAfter.insert(newStart - 1)
            } else {
                let kind: Kind = oldCount == 0 ? .added : .modified
                for line in newStart..<(newStart + newCount) { kinds[line] = kind }
            }
        }
        self.hunks = hunks
        self.kinds = kinds
        self.deletedAfter = deletedAfter
    }

    /// The HEAD line that a buffer line came from, or nil if the line is new or changed.
    func headLine(for line: Int) -> Int? {
        var shift = 0
        for hunk in hunks {
            if line < hunk.newStart { break }
            if line < hunk.newStart + hunk.newCount { return nil }
            shift += hunk.oldCount - hunk.newCount
        }
        return line + shift
    }

    private static let header = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@")
}

/// The commit that last changed each line of HEAD's copy of a file.
nonisolated struct GitBlame: Sendable, Equatable {
    struct Commit: Sendable, Equatable {
        var author = ""
        var date = Date.distantPast
        var summary = ""
    }

    private let commits: [Commit]
    /// An index into `commits` for each line, in file order.
    private let lines: [Int]

    /// Parses `git blame --porcelain`, which describes each commit once and then refers to it by hash.
    init(porcelain: String) {
        var commits: [Commit] = []
        var indices: [Substring: Int] = [:]
        var lines: [Int] = []
        var current = 0
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            // Source lines are tab-prefixed, so they can never be read as metadata.
            guard !line.hasPrefix("\t"), let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space]
            let value = line[line.index(after: space)...]
            switch key {
            case "author": commits[current].author = String(value)
            case "author-time": commits[current].date = Date(timeIntervalSince1970: TimeInterval(value) ?? 0)
            case "summary": commits[current].summary = String(value)
            default:
                // A line header: "<hash> <original line> <final line> [<lines in group>]".
                guard key.count >= 40, key.allSatisfy(\.isHexDigit) else { continue }
                if let index = indices[key] {
                    current = index
                } else {
                    current = commits.count
                    indices[key] = current
                    commits.append(Commit())
                }
                lines.append(current)
            }
        }
        self.commits = commits
        self.lines = lines
    }

    func commit(atLine line: Int) -> Commit? {
        lines.indices.contains(line - 1) ? commits[lines[line - 1]] : nil
    }
}

/// Diffs editor buffers against HEAD. It keeps HEAD's copy of the current file on
/// disk, so typing costs one `git diff` and no object lookup.
actor GitFileAnnotator {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rune-git-\(UUID().uuidString)", isDirectory: true)
    private var fileURL: URL?
    private var head: String?
    private var hasBase = false

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Returns nil if HEAD does not have the file, such as an untracked or ignored file.
    func changes(in text: String, fileURL: URL, head: String) -> GitLineChanges? {
        let base = directory.appendingPathComponent("head")
        let buffer = directory.appendingPathComponent("buffer")
        do {
            if self.fileURL != fileURL || self.head != head {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.fileURL = fileURL
                self.head = head
                hasBase = false
                if let contents = GitRepository.headContents(of: fileURL) {
                    try contents.write(to: base)
                    hasBase = true
                }
            }
            guard hasBase else { return nil }
            try Data(text.utf8).write(to: buffer)
        } catch {
            return nil
        }
        return GitRepository.lineChanges(from: base, to: buffer)
    }
}
