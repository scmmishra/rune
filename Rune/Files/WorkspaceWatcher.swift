import Combine
import CoreServices
import Foundation

@MainActor
final class WorkspaceWatcher: ObservableObject {
    @Published private(set) var revision = 0

    private let rootURL: URL
    private let debounceDuration: Duration
    private var stream: FSEventStreamRef?
    private var refreshTask: Task<Void, Never>?

    init(rootURL: URL, debounceDuration: Duration = .milliseconds(120)) {
        self.rootURL = rootURL
        self.debounceDuration = debounceDuration
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                watcher.scheduleRefresh()
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }

        self.stream = stream
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled else { return }
            revision &+= 1
        }
    }
}
