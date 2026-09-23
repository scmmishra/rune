import AppKit

/// Creating, renaming, duplicating and trashing files from the tree. Every operation
/// returns the resulting URL so the tree can select what the person just made.
nonisolated enum FileTreeActions {
    enum Failure: LocalizedError {
        case emptyName
        case invalidName
        case exists(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a name."
            case .invalidName: "A name cannot contain “/” or “:”."
            case let .exists(name): "“\(name)” already exists here."
            }
        }
    }

    /// Finder's rules: no path separators, and “:” is one in disguise.
    static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        guard !trimmed.contains("/"), !trimmed.contains(":") else { throw Failure.invalidName }
        return trimmed
    }

    static func createFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: try validate(name))
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(url.lastPathComponent) }
        // Intermediate directories let a name like "api/routes.swift" create its folder too.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    static func createFolder(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: try validate(name), directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(url.lastPathComponent) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        let name = try validate(name)
        guard name != url.lastPathComponent else { return url }
        let destination = url.deletingLastPathComponent().appending(path: name)
        // A case-only rename moves onto itself on a case-insensitive volume, so skip the check.
        if name.lowercased() != url.lastPathComponent.lowercased() {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.exists(name) }
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func duplicate(_ url: URL) throws -> URL {
        let destination = availableURL(like: url)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Trash rather than delete: the tree is not the place to lose work irrecoverably.
    static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// "App.swift" → "App copy.swift" → "App copy 2.swift", as Finder names duplicates.
    static func availableURL(like url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for attempt in 1 ... 1_000 {
            let name = attempt == 1 ? "\(base) copy" : "\(base) copy \(attempt)"
            let candidate = directory
                .appending(path: ext.isEmpty ? name : "\(name).\(ext)", directoryHint: isDirectory ? .isDirectory : .notDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appending(path: "\(base) copy \(UUID().uuidString)")
    }
}
