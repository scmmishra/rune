import Foundation

/// A link activated inside a terminal: a local file Rune can open, or anything else.
nonisolated enum TerminalLink: Sendable {
    case file(URL, line: Int?)
    case external(URL)

    /// Ghostty reports the raw link text. Paths may carry a `:line[:column]` suffix or a
    /// `#L12` fragment, which compilers, test runners and agents all print.
    static func parse(_ raw: String, relativeTo directory: URL?) -> TerminalLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme != "file" {
            return .external(url)
        }
        var path = trimmed
        var line: Int?
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "file" {
            path = url.path
            // GitHub-style anchors: file:///…/App.swift#L42
            if let fragment = url.fragment, fragment.first == "L", let value = Int(fragment.dropFirst()) {
                line = value
            }
        }
        if line == nil {
            // Trailing :line or :line:column, keeping Windows-style drive letters intact.
            let parts = path.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 2, let value = Int(parts[1 ... min(2, parts.count - 1)].first ?? ""), value > 0 {
                line = value
                path = String(parts[0])
            }
        }
        path = (path as NSString).expandingTildeInPath
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : directory.map { URL(fileURLWithPath: path, relativeTo: $0) } ?? URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            // Not a path Rune can resolve: let the system decide what it is.
            return URL(string: trimmed).map { .external($0) }
        }
        return isDirectory.boolValue ? .external(url) : .file(url.standardizedFileURL, line: line)
    }
}
