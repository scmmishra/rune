import AppKit
import Combine

@MainActor
final class ChangeGuideModel: ObservableObject {
    struct Entry {
        let guide: ChangeGuide
        let snapshot: GuideSnapshot
        let agent: GuideAgent
    }

    @Published var scope: GuideScope = .workingTree
    @Published var agent: GuideAgent = GuideAgent(rawValue: UserDefaults.standard.string(forKey: "guideAgent") ?? "") ?? .codex {
        didSet { UserDefaults.standard.set(agent.rawValue, forKey: "guideAgent") }
    }
    @Published var selectedSection = -1
    @Published private(set) var entries: [GuideScope: Entry] = [:]
    @Published private(set) var currentSnapshot: GuideSnapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    private var generation: Task<Void, Never>?
    private let runner = GuideAgentRunner()
    private var checkID = UUID()
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.totalCostLimit = 24_000_000
        if agent.executable == nil, let installed = GuideAgent.allCases.first(where: { $0.executable != nil }) { agent = installed }
    }

    var entry: Entry? { entries[scope] }
    var isStale: Bool { !isChecking && entry != nil && entry?.snapshot.fingerprint != currentSnapshot?.fingerprint }

    func check(rootURL: URL) async {
        let id = UUID()
        checkID = id
        let scope = scope
        isChecking = true
        currentSnapshot = nil
        errorMessage = nil
        let capture = Task.detached(priority: .utility) {
            Result { try GuideSnapshot.capture(at: rootURL, scope: scope) }
        }
        // SwiftUI cancels superseded checks; propagate that to the off-main Git work.
        let result = await withTaskCancellationHandler {
            await capture.value
        } onCancel: {
            capture.cancel()
        }
        guard checkID == id, !Task.isCancelled else { return }
        isChecking = false
        switch result {
        case let .success(snapshot): currentSnapshot = snapshot
        case let .failure(error): errorMessage = error.localizedDescription
        }
    }

    func generate(rootURL: URL) {
        guard !isGenerating, !isChecking, let snapshot = currentSnapshot else { return }
        let agent = agent
        isGenerating = true
        errorMessage = nil
        generation = Task {
            defer { isGenerating = false; generation = nil }
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
