import Foundation

@main
struct ChangeGuideChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rune-guide-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appending(path: name))
        }
        try git(["init", "-b", "main"])
        try write("example.swift", "let greeting = \"Hello\"\n")
        try git(["add", "."])
        try git(["-c", "user.name=Rune Checks", "-c", "user.email=checks@example.invalid", "commit", "-m", "fixture"])
        precondition(!GitRepository.guideBranches(at: root).allowsPR)
        try git(["checkout", "-b", "feature"])
        try write("feature[1].swift", "let feature = true\n")
        try git(["add", "."])
        try git(["-c", "user.name=Rune Checks", "-c", "user.email=checks@example.invalid", "commit", "-m", "feature"])
        try git(["checkout", "main"])
        try write("base-only.swift", "let base = true\n")
        try git(["add", "."])
        try git(["-c", "user.name=Rune Checks", "-c", "user.email=checks@example.invalid", "commit", "-m", "base"])
        try git(["checkout", "feature"])
        precondition(GitRepository.guideBranches(at: root).allowsPR)
        try write("example.swift", "let greeting = \"Hello, world\"\n")
        try git(["add", "."])
        try write("example.swift", "let greeting = \"Welcome\"\n")
        try write("new file.swift", "let enabled = true\n")
        let pr = try GuideSnapshot.capture(at: root, scope: .pr, comparison: "main")
        precondition(pr.files.map(\.path) == ["feature[1].swift"], "PR must exclude base-only, staged, and untracked edits and preserve literal paths")
        do {
            _ = try GuideSnapshot.capture(at: root, scope: .pr, comparison: "missing-branch")
            preconditionFailure("Unknown comparison must fail")
        } catch { }
        let staged = try GuideSnapshot.capture(at: root, scope: .staged)
        let working = try GuideSnapshot.capture(at: root, scope: .workingTree)
        precondition(staged.files.count == 1)
        precondition(staged.files[0].patch.contains("+let greeting = \"Hello, world\""))
        precondition(!staged.files[0].patch.contains("Welcome"))
        precondition(working.files.count == 2)
        precondition(working.files[0].patch.contains("+let greeting = \"Welcome\""))
        precondition(staged.fingerprint != working.fingerprint)
        let repeated = try GuideSnapshot.capture(at: root, scope: .workingTree)
        precondition(repeated.fingerprint == working.fingerprint)
        try write("new file.swift", "let enabled = false\n")
        let updated = try GuideSnapshot.capture(at: root, scope: .workingTree)
        precondition(updated.fingerprint != working.fingerprint, "Content-only edits must invalidate a guide")
        let section = ChangeGuide.Section(title: "Greeting", explanation: "Updates the greeting.", mermaid: "", references: [staged.references[0].id])
        let guide = ChangeGuide(title: "Greeting change", overview: "Updates the greeting.", sections: [section])
        try guide.validate(against: staged)
        let encoded = try JSONEncoder().encode(guide)
        _ = try GuideAgent.codex.decode(encoded)
        let envelope = "{\"is_error\":false,\"structured_output\":\(String(decoding: encoded, as: UTF8.self))}"
        _ = try GuideAgent.claude.decode(Data(envelope.utf8))
        let invalid = ChangeGuide(title: "Bad", overview: "Bad reference", sections: [
            .init(title: "Bad", explanation: "Bad", mermaid: "", references: ["../../outside"])
        ])
        do { try invalid.validate(against: staged); preconditionFailure("Untrusted references must fail") } catch { }
        do { _ = try GuideAgent.claude.decode(Data(#"{"is_error":true,"result":"Failed"}"#.utf8)); preconditionFailure("Agent errors must fail") } catch { }
        let metadata = GuideSnapshot(scope: .staged, branch: "main", files: [.init(path: "binary", patch: "Binary files differ")])
        precondition(metadata.references.count == 1 && metadata.references[0].id == "f0")
        print("Change guide checks passed: staging boundaries, untracked files, fingerprints, references, and provider decoding.")
        if let argument = CommandLine.arguments.dropFirst().first,
           let agent = GuideAgent.allCases.first(where: { $0.command == argument }) {
            let result = try await GuideAgentRunner().generate(agent: agent, snapshot: staged, rootURL: root)
            print("Live \(agent.rawValue) generation passed: \(result.sections.count) sections with validated code references.")
        }
    }
}
