import Foundation

@main
struct TerminalLinkChecks {
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let file = root.appending(path: "pkg/sub/File.swift")

        func parse(_ raw: String, base: URL? = nil) -> TerminalLink? {
            TerminalLink.parse(raw, relativeTo: base ?? root)
        }
        func expectFile(_ raw: String, _ expected: URL, line expectedLine: Int?, _ message: String) {
            guard case let .file(url, line) = parse(raw) else { preconditionFailure(message + " (not a file)") }
            precondition(url == expected.standardizedFileURL, message + " (path: \(url.path))")
            precondition(line == expectedLine, message + " (line: \(String(describing: line)))")
        }
        func expectExternal(_ raw: String, _ message: String) {
            guard case .external = parse(raw) else { preconditionFailure(message) }
        }

        expectFile(file.path, file, line: nil, "An absolute path opens in Rune")
        expectFile(file.path + ":42", file, line: 42, "A trailing :line is a line number")
        expectFile(file.path + ":42:7", file, line: 42, "A :line:column keeps the line")
        expectFile("file://" + file.path, file, line: nil, "A file URL opens in Rune")
        expectFile("file://" + file.path + "#L12", file, line: 12, "A #L fragment is a line number")
        expectFile("pkg/sub/File.swift", file, line: nil, "A relative path resolves against the shell's directory")
        expectFile("pkg/sub/File.swift:3", file, line: 3, "A relative path keeps its line")
        expectFile("  " + file.path + "  ", file, line: nil, "Surrounding whitespace is ignored")

        expectExternal("https://github.com/scmmishra/rune", "Web links stay with the system browser")
        expectExternal("mailto:someone@example.com", "Other schemes stay with the system")
        expectExternal(root.path, "A directory is not opened in the editor")
        expectExternal("pkg/sub/Missing.swift", "A path that does not exist is left to the system")
        precondition(parse("") == nil, "Empty text is not a link")
        precondition(parse("   ") == nil, "Blank text is not a link")

        // A file whose name contains a colon must not lose its suffix to a line number.
        let odd = root.appending(path: "pkg/sub/od:d.swift")
        try? Data("x".utf8).write(to: odd)
        expectFile(odd.path, odd, line: nil, "A colon inside a filename is part of the path")

        print("Terminal link checks passed")
    }
}
