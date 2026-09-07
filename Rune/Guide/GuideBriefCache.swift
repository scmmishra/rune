import Foundation
import CryptoKit

nonisolated struct GuideBriefCache: Sendable {
    struct Record: Codable, Sendable {
        let guide: ChangeGuide
        let agentName: String
        let fingerprint: String
    }

    let directory: URL
    private static let maximumEntries = 20
    private static let maximumBytes = 1_000_000

    init(rootURL: URL, storageURL: URL? = nil) {
        let project = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined()
        let storage = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rune/ChangeBriefs")
        // Version the format so future incompatible entries become cache misses.
        directory = storage.appending(path: "v1").appending(path: key)
    }

    func load(snapshot: GuideSnapshot) -> Record? {
        let url = directory.appending(path: snapshot.fingerprint + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.fingerprint == snapshot.fingerprint,
              GuideAgent(rawValue: record.agentName) != nil,
              (try? record.guide.validate(against: snapshot)) != nil else { return nil }
        return record
    }

    func save(guide: ChangeGuide, agent: GuideAgent, snapshot: GuideSnapshot) throws {
        try guide.validate(against: snapshot)
        let record = Record(guide: guide, agentName: agent.rawValue, fingerprint: snapshot.fingerprint)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumBytes else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: snapshot.fingerprint + ".json"), options: .atomic)
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for file in files.dropFirst(Self.maximumEntries) { try? manager.removeItem(at: file) }
    }
}
