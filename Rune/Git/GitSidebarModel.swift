import Combine
import Foundation

@MainActor
final class GitSidebarModel: ObservableObject {
    private static let indexRefreshFallbackDelay = Duration.milliseconds(750)

    @Published private(set) var snapshot = GitSnapshot.empty
    @Published private(set) var isCommitting = false
    @Published private(set) var isTrashing = false
    @Published private(set) var isDiscarding = false
    @Published private var repositoryErrorMessage: String?
    @Published private var actionErrorMessage: String?

    private let rootURL: URL
    private var refreshTask: Task<Void, Never>?
    private var indexRefreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var isUpdatingIndex = false

    var errorMessage: String? {
        actionErrorMessage ?? repositoryErrorMessage
    }

    var isBusy: Bool {
        isCommitting || isTrashing || isDiscarding
    }

    private var isPerformingAction: Bool {
        isBusy || isUpdatingIndex
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func refresh() {
        guard !isPerformingAction, refreshTask == nil else {
            refreshRequested = true
            return
        }

        refreshRequested = false
        let rootURL = rootURL

        refreshTask = Task {
            let result = await Task.detached(priority: .utility) {
                GitRepository.snapshot(at: rootURL)
            }.value

            guard !Task.isCancelled else { return }
            if snapshot != result.snapshot {
                snapshot = result.snapshot
            }
            if repositoryErrorMessage != result.errorMessage {
                repositoryErrorMessage = result.errorMessage
            }
            refreshTask = nil

            if refreshRequested {
                refreshRequested = false
                refresh()
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        indexRefreshTask?.cancel()
        indexRefreshTask = nil
        refreshRequested = false
    }

    func refreshFromWatcher() {
        indexRefreshTask?.cancel()
        indexRefreshTask = nil
        refresh()
    }

    func commitStaged(message: String) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isPerformingAction else { return false }

        cancelRefresh()
        isCommitting = true
        actionErrorMessage = nil

        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.commitStaged(message: message, at: rootURL)
        }.value

        isCommitting = false
        actionErrorMessage = result.errorMessage
        refresh()
        return result.succeeded
    }

    func stage(_ change: GitChange) async {
        await updateIndex(.stage(paths: change.paths))
    }

    func unstage(_ change: GitChange) async {
        await updateIndex(.unstage(paths: change.paths))
    }

    func stageAll() async {
        await updateIndex(.stageAll)
    }

    func unstageAll() async {
        await updateIndex(.unstageAll)
    }

    func trash(_ change: GitChange) async {
        guard !isPerformingAction else { return }

        let rootURL = rootURL.standardizedFileURL
        let fileURL = rootURL.appending(path: change.path).standardizedFileURL
        guard fileURL.path.hasPrefix(rootURL.path + "/") else {
            actionErrorMessage = "Cannot trash a file outside the workspace"
            return
        }

        cancelRefresh()
        isTrashing = true
        actionErrorMessage = nil

        let errorMessage = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                return nil as String?
            } catch {
                return error.localizedDescription
            }
        }.value

        isTrashing = false
        actionErrorMessage = errorMessage
        refresh()
    }

    func discard(_ change: GitChange) async {
        guard !isPerformingAction else { return }

        if change.unstagedState == .untracked {
            await trash(change)
            return
        }

        cancelRefresh()
        isDiscarding = true
        actionErrorMessage = nil

        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.discardChanges(for: change, at: rootURL)
        }.value

        isDiscarding = false
        actionErrorMessage = result.errorMessage
        refresh()
    }

    private func updateIndex(_ action: GitRepository.IndexAction) async {
        guard !isPerformingAction else { return }

        cancelRefresh()
        let previousSnapshot = snapshot
        if actionErrorMessage != nil {
            actionErrorMessage = nil
        }
        // Move rows immediately while Git updates the index. The authoritative
        // refresh reconciles partial staging and rename edge cases afterward.
        let optimisticSnapshot = snapshot.applying(action)
        if snapshot != optimisticSnapshot {
            snapshot = optimisticSnapshot
        }
        isUpdatingIndex = true

        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.updateIndex(action, at: rootURL)
        }.value

        isUpdatingIndex = false
        if actionErrorMessage != result.errorMessage {
            actionErrorMessage = result.errorMessage
        }
        guard result.succeeded else {
            snapshot = previousSnapshot
            return
        }

        scheduleIndexRefresh()
    }

    private func scheduleIndexRefresh() {
        indexRefreshTask?.cancel()
        indexRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.indexRefreshFallbackDelay)
            guard !Task.isCancelled, let self else { return }
            indexRefreshTask = nil
            refresh()
        }
    }
}
