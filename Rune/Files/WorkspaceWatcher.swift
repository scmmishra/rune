import Combine
import CoreServices
import Foundation

@MainActor
final class WorkspaceWatcher: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var requiresFileIndexRefresh = true
    private(set) var requiresHistoryRefresh = true
    private var pendingIndexRefresh = false
    private var pendingHistoryRefresh = false

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

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var needsIndex = paths.count != count
            var needsHistory = needsIndex
            for index in 0..<count {
                let flags = eventFlags[index]
                let rescan = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
                    kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped |
                    kFSEventStreamEventFlagKernelDropped) != 0
                let path = index < paths.count ? paths[index] : ""
                let gitMetadata = path.contains("/.git/") || path.hasSuffix("/.git")
                needsHistory = needsHistory || rescan || gitMetadata
                needsIndex = needsIndex || rescan || gitMetadata || path.hasSuffix("/.gitignore") ||
                    flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated |
                        kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
            }
            let indexRefresh = needsIndex
            let historyRefresh = needsHistory
            Task { @MainActor in
                watcher.scheduleRefresh(index: indexRefresh, history: historyRefresh)
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes |
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

    private func scheduleRefresh(index: Bool, history: Bool) {
        pendingIndexRefresh = pendingIndexRefresh || index
        pendingHistoryRefresh = pendingHistoryRefresh || history
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled else { return }
            requiresFileIndexRefresh = pendingIndexRefresh
            requiresHistoryRefresh = pendingHistoryRefresh
            pendingIndexRefresh = false
            pendingHistoryRefresh = false
            revision &+= 1
        }
    }
}
