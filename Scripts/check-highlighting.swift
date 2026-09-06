import AppKit

@main
struct HighlightingChecks {
    static func main() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let samples = [
            ("swift", "func greet() {\n  let message = \"hello 🌍\"\n  print(message)\n}\n"),
            ("rb", "def greet\n  message = \"hello 🌍\"\n  puts message\nend\n"),
            ("go", "package main\nfunc greet() {\n  message := \"hello 🌍\"\n  println(message)\n}\n")
        ]
        for (ext, initial) in samples {
            let url = URL(fileURLWithPath: "sample." + ext)
            let incremental = SyntaxHighlighter(fileURL: url, font: font)
            // Include empty documents, multiline edits, CRLF, and edits inside surrogate pairs.
            let versions = [initial, initial.replacingOccurrences(of: "🌍", with: "🌎"),
                            initial.replacingOccurrences(of: "hello", with: "hi\nthere"),
                            initial.replacingOccurrences(of: "\n", with: "\r\n"),
                            "", initial, initial + initial, String(initial.dropLast(4)), initial]
            for source in versions {
                let actual = incremental.highlight(source)
                let expected = SyntaxHighlighter(fileURL: url, font: font).highlight(source)
                precondition(actual.isEqual(to: expected), "Incremental highlighting differs for \(ext)")
            }
            print("PASS: \(ext) incremental highlighting matches fresh parsing across \(versions.count) edits")
        }
    }
}
