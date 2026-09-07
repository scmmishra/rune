import Foundation
import CryptoKit

nonisolated struct ProjectCommand: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    var workingDirectory = "."
    var autoStart = false

    func directory(relativeTo root: URL) -> URL {
        let path = (workingDirectory as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }
}

nonisolated struct Procfile: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let commands: [ProjectCommand]
    let warnings: [String]

    static func parse(_ contents: String, url: URL) -> Procfile {
        var commands: [ProjectCommand] = []
        var warnings: [String] = []
        var names: Set<String> = []
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let line = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                warnings.append("Line \(index + 1): expected name: command")
                continue
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let command = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  !command.isEmpty, !command.contains("\0") else {
                warnings.append("Line \(index + 1): invalid name or empty command")
                continue
            }
            guard names.insert(name).inserted else {
                warnings.append("Line \(index + 1): duplicate process \(name)")
                continue
            }
            commands.append(ProjectCommand(name: name, command: command))
        }
        return Procfile(url: url, commands: commands, warnings: warnings)
    }

    static func discover(in root: URL) throws -> [Procfile] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            .filter { $0.lastPathComponent == "Procfile" || $0.lastPathComponent.hasPrefix("Procfile.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { return nil }
                // Discovery must stay bounded even if a matching file is a log or binary.
                guard (values.fileSize ?? 0) <= 1_048_576 else {
                    return Procfile(url: url, commands: [], warnings: ["File exceeds 1 MB."])
                }
                do { return parse(try String(contentsOf: url, encoding: .utf8), url: url) }
                catch { return Procfile(url: url, commands: [], warnings: [error.localizedDescription]) }
            }
    }
}

nonisolated struct ProjectCommandStorage: Sendable {
    let fileURL: URL

    init(root: URL, baseDirectory: URL = URL.applicationSupportDirectory.appendingPathComponent("Rune/Commands")) {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        fileURL = baseDirectory.appendingPathComponent(key + ".json")
    }

    func load() throws -> [ProjectCommand] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ProjectCommand].self, from: Data(contentsOf: fileURL))
    }

    func save(_ commands: [ProjectCommand]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(commands).write(to: fileURL, options: .atomic)
    }

    func resetKeepingBackup() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("backup-" + UUID().uuidString))
        }
        try save([])
    }
}
