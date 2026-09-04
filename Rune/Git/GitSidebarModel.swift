import Combine
import Foundation

@MainActor
final class GitSidebarModel: ObservableObject {
    @Published private(set) var snapshot = GitSnapshot.empty
    @Published private(set) var isCommitting = false
    @Published private(set) var isUpdatingIndex = false
    @Published private(set) var isTrashing = false
    @Published private(set) var isDiscarding = false
    @Published private var repositoryErrorMessage: String?
    @Published private var actionErrorMessage: String?

    private let rootURL: URL
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false

    var errorMessage: String? {
        actionErrorMessage ?? repositoryErrorMessage
    }

    var isBusy: Bool {
        isCommitting || isUpdatingIndex || isTrashing || isDiscarding
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func refresh() {
        guard !isBusy, refreshTask == nil else {
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
            snapshot = result.snapshot
            repositoryErrorMessage = result.errorMessage
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
        refreshRequested = false
    }

    func commitStaged(message: String) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isBusy else { return false }

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
        guard !isBusy else { return }

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
        guard !isBusy else { return }

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
        guard !isBusy else { return }

        cancelRefresh()
        isUpdatingIndex = true
        actionErrorMessage = nil

        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.updateIndex(action, at: rootURL)
        }.value

        isUpdatingIndex = false
        actionErrorMessage = result.errorMessage
        refresh()
    }
}
