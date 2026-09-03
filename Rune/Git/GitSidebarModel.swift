import Combine
import Foundation

@MainActor
final class GitSidebarModel: ObservableObject {
    @Published private(set) var snapshot = GitSnapshot.empty
    @Published private(set) var isCommitting = false
    @Published private var repositoryErrorMessage: String?
    @Published private var commitErrorMessage: String?

    private let rootURL: URL
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false

    var errorMessage: String? {
        commitErrorMessage ?? repositoryErrorMessage
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func refresh() {
        guard !isCommitting, refreshTask == nil else {
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

    func commitAll(message: String) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isCommitting else { return false }

        cancelRefresh()
        isCommitting = true
        commitErrorMessage = nil

        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.commitAll(message: message, at: rootURL)
        }.value

        isCommitting = false
        commitErrorMessage = result.errorMessage
        refresh()
        return result.succeeded
    }
}
