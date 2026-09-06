import Combine
import Foundation

@MainActor
final class GitSidebarModel: ObservableObject {
    private static let indexRefreshFallbackDelay = Duration.milliseconds(750)

    @Published private(set) var snapshot = GitSnapshot.empty
    @Published private(set) var files: [WorkspaceFileIndex.Entry] = []
    @Published private(set) var revision = 0
    @Published private(set) var contentRevision = 0
    @Published private(set) var hasLoaded = false
    private let watcher: WorkspaceWatcher
    private var watcherSubscription: AnyCancellable?
    @Published private(set) var isCommitting = false
    @Published private(set) var isTrashing = false
    @Published private(set) var isDiscarding = false
    @Published private(set) var isSwitchingBranch = false
    @Published private var repositoryErrorMessage: String?
    @Published private var actionErrorMessage: String?

    private let rootURL: URL
    private var refreshTask: Task<Void, Never>?
    private var indexRefreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var isUpdatingIndex = false
    private var needsFileIndex = true
    private var needsHistory = true
    private var historyUpdatedAt = Date.distantPast

    var errorMessage: String? {
        actionErrorMessage ?? repositoryErrorMessage
    }

    var isBusy: Bool {
        isCommitting || isTrashing || isDiscarding || isSwitchingBranch
    }

    private var isPerformingAction: Bool {
        isBusy || isUpdatingIndex
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        watcher = WorkspaceWatcher(rootURL: rootURL, debounceDuration: .milliseconds(300))
    }

    func start() {
        guard watcherSubscription == nil else { return }
        watcherSubscription = watcher.$revision.dropFirst().sink { [weak self] _ in
            self?.refreshFromWatcher()
        }
        watcher.start()
        refresh()
    }

    func stop() {
        watcher.stop()
        watcherSubscription = nil
        cancelRefresh()
    }

    func reload() {
        // Invalidate both caches even if an in-flight Git operation defers the refresh.
        needsFileIndex = true
        needsHistory = true
        contentRevision &+= 1
        refresh()
    }

    func switchBranch(_ name: String, create: Bool) async -> Bool {
        guard !isPerformingAction else { return false }
        cancelRefresh()
        isSwitchingBranch = true
        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.switchBranch(name, create: create, at: rootURL)
        }.value
        isSwitchingBranch = false
        actionErrorMessage = result.errorMessage
        refresh()
        return result.succeeded
    }

    func refresh() {
        guard !isPerformingAction, refreshTask == nil else {
            refreshRequested = true
            return
        }

        refreshRequested = false
        let rootURL = rootURL
        let cachedFiles = needsFileIndex ? nil : files
        let cachedCommits = needsHistory || Date().timeIntervalSince(historyUpdatedAt) > 60 ? nil : snapshot.commits
        needsFileIndex = false
        needsHistory = false

        refreshTask = Task {
            let result = await Task.detached(priority: .utility) {
                (GitRepository.snapshot(at: rootURL, cachedCommits: cachedCommits),
                 cachedFiles ?? WorkspaceFileIndex.files(in: rootURL))
            }.value

            guard !Task.isCancelled else { return }
            // Ignored files and empty folders can change without changing Git's file
            // list. A structural refresh must also rebuild the visible filesystem tree.
            let changed = cachedFiles == nil ||
                snapshot.isRepository != result.0.snapshot.isRepository || files != result.1 ||
                snapshot.changes.count != result.0.snapshot.changes.count ||
                zip(snapshot.changes, result.0.snapshot.changes).contains {
                    $0.path != $1.path || $0.stagedState != $1.stagedState || $0.unstagedState != $1.unstagedState
                }
            if snapshot != result.0.snapshot {
                snapshot = result.0.snapshot
            }
            if files != result.1 { files = result.1 }
            if changed || !hasLoaded { revision &+= 1 }
            hasLoaded = true
            if cachedCommits == nil { historyUpdatedAt = Date() }
            if repositoryErrorMessage != result.0.errorMessage {
                repositoryErrorMessage = result.0.errorMessage
            }
            refreshTask = nil

            if refreshRequested {
                refreshRequested = false
                refresh()
            }
        }
    }

    func cancelRefresh() {
        contentRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        indexRefreshTask?.cancel()
        indexRefreshTask = nil
        refreshRequested = false
        needsFileIndex = true
        needsHistory = true
    }

    func refreshFromWatcher() {
        contentRevision &+= 1
        needsFileIndex = needsFileIndex || watcher.requiresFileIndexRefresh
        needsHistory = needsHistory || watcher.requiresHistoryRefresh
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
