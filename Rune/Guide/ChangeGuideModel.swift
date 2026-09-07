import AppKit
import Combine

@MainActor
final class ChangeGuideModel: ObservableObject {
    struct Entry {
        let guide: ChangeGuide
        let snapshot: GuideSnapshot
        let agent: GuideAgent
    }

    @Published var scope: GuideScope {
        didSet { preferences.set(scope.rawValue, forKey: preferenceKey + ".scope"); invalidate() }
    }
    @Published var comparisonBranch: String {
        didSet { preferences.set(comparisonBranch, forKey: preferenceKey + ".comparison"); invalidate() }
    }
    @Published private(set) var allowsPR = false
    private let preferences: UserDefaults
    private let preferenceKey: String
    private var needsDefaultComparison: Bool
    private func invalidate() {
        checkID = UUID()
        currentSnapshot = nil
        errorMessage = nil
    }
    var openFromPalette = false
    @Published var paletteRequestID = UUID()
    @Published var selectedSection = -1
    @Published private(set) var entries: [GuideScope: Entry] = [:]
    @Published private(set) var currentSnapshot: GuideSnapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var generatingAgent: GuideAgent?
    @Published private(set) var errorMessage: String?
    private var generation: Task<Void, Never>?
    private let runner = GuideAgentRunner()
    private var checkID = UUID()
    private let images = NSCache<NSString, NSImage>()

    init(rootURL: URL, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        preferenceKey = "changeGuide." + rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        needsDefaultComparison = preferences.object(forKey: preferenceKey + ".comparison") == nil
        scope = preferences.string(forKey: preferenceKey + ".scope").flatMap(GuideScope.init(rawValue:)) ?? .workingTree
        comparisonBranch = preferences.string(forKey: preferenceKey + ".comparison") ?? ""
        images.totalCostLimit = 24_000_000
    }

    var isGenerating: Bool { generatingAgent != nil }
    var entry: Entry? {
        guard let entry = entries[scope], scope != .pr || entry.snapshot.comparison == comparisonBranch.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return entry
    }
    var isStale: Bool { !isChecking && entry != nil && entry?.snapshot.fingerprint != currentSnapshot?.fingerprint }

    func check(rootURL: URL) async {
        let id = UUID()
        checkID = id
        let scope = scope
        let comparison = comparisonBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let useDefaultComparison = needsDefaultComparison
        isChecking = true
        currentSnapshot = nil
        errorMessage = nil
        let capture = Task.detached(priority: .utility) {
            let branches = GitRepository.guideBranches(at: rootURL)
            let result = Result { try GuideSnapshot.capture(at: rootURL, scope: scope, comparison: useDefaultComparison ? branches.comparison : comparison) }
            return (branches, result)
        }
        // SwiftUI cancels superseded checks; propagate that to the off-main Git work.
        let result = await withTaskCancellationHandler {
            await capture.value
        } onCancel: {
            capture.cancel()
        }
        guard checkID == id, !Task.isCancelled else { return }
        allowsPR = result.0.allowsPR
        if needsDefaultComparison && !result.0.comparison.isEmpty {
            needsDefaultComparison = false
            comparisonBranch = result.0.comparison
        }
        isChecking = false
        switch result.1 {
        case let .success(snapshot): currentSnapshot = snapshot
        case let .failure(error): errorMessage = error.localizedDescription
        }
    }

    func generate(rootURL: URL, agent: GuideAgent) {
        guard !isGenerating, !isChecking, let snapshot = currentSnapshot else { return }
        generatingAgent = agent
        errorMessage = nil
        generation = Task {
            defer { generatingAgent = nil; generation = nil }
            do {
                let guide = try await runner.generate(agent: agent, snapshot: snapshot, rootURL: rootURL)
                try Task.checkCancellation()
                entries[snapshot.scope] = Entry(guide: guide, snapshot: snapshot, agent: agent)
                selectedSection = -1
            } catch is CancellationError {
                // Cancelling a refresh preserves the previous readable guide.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        generation?.cancel()
        runner.cancel()
    }

    func diagram(source: String, dark: Bool) async throws -> NSImage? {
        let key = ((dark ? "dark:" : "light:") + source) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image = try await Task.detached(priority: .utility) {
            try GuideDiagramRenderer.render(source: source, dark: dark)
        }.value
        try Task.checkCancellation()
        if let image {
            images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 16))
        }
        return image
    }
}
