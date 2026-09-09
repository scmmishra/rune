import AppKit
import SwiftUI

struct FileTreeView<Terminals: View>: View {
    @ViewBuilder let terminals: () -> Terminals
    let rootURL: URL
    let onOpenFile: (URL) -> Void
    let onOpenProjects: () -> Void
    let topInset: CGFloat
    @State private var isTitleHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
            Text(rootURL.lastPathComponent)
                .runeFont(size: 12, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(isTitleHovered ? 0.06 : 0))
                        .padding(-4)
                }
                .padding(.horizontal, WorkspaceMetrics.columnInset)
                .onHover { isTitleHovered = $0 }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenProjects)
                .help("Switch Project (⇧⌘O)\n" + rootURL.path)
                .accessibilityLabel("Switch project, " + rootURL.lastPathComponent)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpenProjects() }
                .frame(height: WorkspaceMetrics.headerHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .workspaceGroup()

            terminals()

            VStack(alignment: .leading, spacing: 4) {
                Text("FILES")
                    .runeFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, WorkspaceMetrics.columnInset - 4)

                FileTreeContents(rootURL: rootURL, onOpenFile: onOpenFile)
                    .id(rootURL)
                    .safeAreaPadding(.bottom, 48)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspaceGroup()
        }
        .padding(.top, topInset)
    }
}

private struct FileTreeContents: View {
    let rootURL: URL
    let onOpenFile: (URL) -> Void
    @State private var items: [FileTreeItem] = []
    @State private var visibleItems: [VisibleFileTreeItem] = []
    @State private var treeRevision = 0
    @State private var expandedDirectories: Set<URL>
    @State private var selectedURL: URL?
    @State private var hoveredURL: URL?
    @EnvironmentObject private var repository: GitSidebarModel
    @FocusState private var hasKeyboardFocus: Bool
    @Environment(\.runeTypography) private var typography

    init(rootURL: URL, onOpenFile: @escaping (URL) -> Void) {
        self.rootURL = rootURL
        self.onOpenFile = onOpenFile
        let paths = UserDefaults.standard.stringArray(forKey: "expandedDirectories:" + rootURL.path) ?? []
        _expandedDirectories = State(initialValue: Set(paths.map { URL(fileURLWithPath: $0, isDirectory: true) }))
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleItems) { visibleItem in
                    treeRow(
                        name: visibleItem.item.name,
                        url: visibleItem.item.url,
                        isDirectory: visibleItem.item.isDirectory,
                        status: visibleItem.item.status,
                        depth: visibleItem.depth
                    )
                    .id(visibleItem.item.url)
                }
            }
            .padding(.horizontal, WorkspaceMetrics.columnInset - 4)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onChange(of: selectedURL) { _, selected in
            if let selected { proxy.scrollTo(selected) }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { keyPress in
            handleKeyPress(keyPress.key)
        }
        .onChange(of: expandedDirectories) {
            UserDefaults.standard.set(expandedDirectories.map(\.path).sorted(), forKey: "expandedDirectories:" + rootURL.path)
        }
        .task(id: ExpansionRequest(revision: treeRevision, directories: expandedDirectories)) {
            let items = items
            let directories = expandedDirectories
            let refreshedRows = await Task.detached(priority: .userInitiated) {
                Self.flattened(items, expandedDirectories: directories)
            }.value
            guard !Task.isCancelled else { return }
            visibleItems = refreshedRows
        }
        .task(id: repository.revision) {
            guard repository.hasLoaded else { return }
            let rootURL = rootURL
            let snapshot = repository.snapshot
            let paths = repository.files.map(\.relativePath)
            let refreshedItems = await Task.detached(priority: .userInitiated) {
                if snapshot.isRepository {
                    let statuses = Dictionary(uniqueKeysWithValues: snapshot.changes.map {
                        ($0.path, $0.unstagedState == .untracked || $0.stagedState == .added
                            ? FileTreeStatus.untracked : FileTreeStatus.modified)
                    })
                    return GitFileTree.makeTree(from: paths, statuses: statuses, rootedAt: rootURL)
                }
                return FileTreeItem.contents(of: rootURL)
            }.value

            guard !Task.isCancelled else { return }
            items = refreshedItems
            treeRevision &+= 1
        }
        }
    }

    private struct ExpansionRequest: Equatable {
        let revision: Int
        let directories: Set<URL>
    }

    nonisolated private static func flattened(
        _ items: [FileTreeItem], expandedDirectories: Set<URL>, depth: Int = 0
    ) -> [VisibleFileTreeItem] {
        items.flatMap { item in
            var result = [VisibleFileTreeItem(item: item, depth: depth)]
            if item.isDirectory,
               expandedDirectories.contains(item.url),
               let children = item.children {
                result.append(contentsOf: flattened(children, expandedDirectories: expandedDirectories, depth: depth + 1))
            }
            return result
        }
    }

    private func treeRow(
        name: String,
        url: URL,
        isDirectory: Bool,
        status: FileTreeStatus?,
        depth: Int
    ) -> some View {
        HStack(spacing: 4) {
            if isDirectory {
                Image(systemName: expandedDirectories.contains(url) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 8)
            } else {
                Color.clear
                    .frame(width: 8)
            }

            FileIconView(url: url, isDirectory: isDirectory)
                .foregroundStyle(status?.color ?? Color.secondary)
                .frame(width: 12, height: 12)

            Text(name)
                .runeFont(size: 12)
                .foregroundStyle(status?.color ?? Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 10)
        .frame(
            maxWidth: .infinity,
            minHeight: max(17, typography.size(relativeTo: 17)),
            alignment: .leading
        )
        .background {
            if selectedURL == url {
                RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius)
                    .fill(Color.accentColor.opacity(hasKeyboardFocus ? 0.20 : 0.10))
            } else if hoveredURL == url {
                RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { hoveredURL = $0 ? url : nil }
        .help(url.path)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedURL = url
            hasKeyboardFocus = true
            activate(url: url, isDirectory: isDirectory)
        }
    }

    private func handleKeyPress(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !visibleItems.isEmpty else { return .ignored }

        if key == .return {
            guard let selectedURL,
                  let selectedItem = visibleItems.first(where: { $0.item.url == selectedURL }) else {
                return .ignored
            }
            activate(url: selectedItem.item.url, isDirectory: selectedItem.item.isDirectory)
            return .handled
        }

        let currentIndex = selectedURL.flatMap { selectedURL in
            visibleItems.firstIndex(where: { $0.item.url == selectedURL })
        }
        let nextIndex: Int

        if key == .upArrow {
            nextIndex = max(0, (currentIndex ?? 1) - 1)
        } else if key == .downArrow {
            nextIndex = min(visibleItems.count - 1, (currentIndex ?? -1) + 1)
        } else {
            return .ignored
        }

        selectedURL = visibleItems[nextIndex].item.url
        return .handled
    }

    private func activate(url: URL, isDirectory: Bool) {
        if isDirectory {
            if expandedDirectories.contains(url) {
                expandedDirectories.remove(url)
            } else {
                expandedDirectories.insert(url)
            }
        } else {
            onOpenFile(url)
        }
    }
}

// SwiftUI does not expose the containing macOS window's full-screen state, so
// observe that specific NSWindow rather than global application notifications.
struct WindowFullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window)
        }
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
    }

    static func dismantleNSView(_ view: WindowTrackingView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.onWindowChange = nil
    }

    @MainActor
    final class Coordinator {
        var isFullScreen: Binding<Bool>

        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        func observe(_ window: NSWindow?) {
            guard self.window !== window else { return }
            stopObserving()
            self.window = window

            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.updateState()
                        }
                    }
                )
            }
            updateState()
        }

        func stopObserving() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            window = nil
        }

        private func updateState() {
            isFullScreen.wrappedValue = window?.styleMask.contains(.fullScreen) == true
        }
    }
}

final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

nonisolated private struct VisibleFileTreeItem: Identifiable, Sendable {
    let item: FileTreeItem
    let depth: Int

    var id: URL { item.id }
}

nonisolated private final class FileTreeItem: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    let status: FileTreeStatus?
    private let loadChildren: (@Sendable () -> [FileTreeItem])?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    // Only expanded folders are read, in the background flattening task. Keep this
    // immutable because a cancelled refresh may overlap the next expansion.
    var children: [FileTreeItem]? { loadChildren?() }

    init(url: URL, isDirectory: Bool, status: FileTreeStatus? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.status = status
        if isDirectory {
            loadChildren = { Self.contents(of: url) }
        } else {
            loadChildren = nil
        }
    }

    init(directoryURL: URL, children: [FileTreeItem], status: FileTreeStatus?) {
        url = directoryURL
        isDirectory = true
        self.status = status
        loadChildren = { Self.mergingContents(of: directoryURL, with: children) }
    }

    static func workspaceContents(of directoryURL: URL) -> [FileTreeItem] {
        GitFileTree.contents(of: directoryURL) ?? contents(of: directoryURL)
    }

    static func contents(of directoryURL: URL) -> [FileTreeItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys)
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.lastPathComponent != ".git" else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            return FileTreeItem(url: url, isDirectory: isDirectory)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func mergingContents(of directoryURL: URL, with indexedItems: [FileTreeItem]) -> [FileTreeItem] {
        // Preserve indexed entries (including deleted tracked files) and their Git
        // status, while exposing ignored files and empty folders without a recursive scan.
        var items = Dictionary(uniqueKeysWithValues: contents(of: directoryURL).map { ($0.name, $0) })
        for item in indexedItems { items[item.name] = item }
        return items.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

nonisolated private enum FileTreeStatus: Equatable, Sendable {
    case modified
    case untracked

    var color: Color {
        switch self {
        case .modified:
            .yellow
        case .untracked:
            .green
        }
    }
}

nonisolated private enum GitFileTree {
    static func contents(of directoryURL: URL) -> [FileTreeItem]? {
        guard let paths = filePaths(in: directoryURL) else {
            return nil
        }

        let statusData = runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no"],
            in: directoryURL
        )
        let statuses = statusData.map(parseStatuses) ?? [:]
        return makeTree(from: paths, statuses: statuses, rootedAt: directoryURL)
    }

    nonisolated static func filePaths(in directoryURL: URL) -> [String]? {
        guard let files = runGit(
            ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            in: directoryURL
        ) else {
            return nil
        }

        return files.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated private static func runGit(_ arguments: [String], in directoryURL: URL) -> Data? {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directoryURL.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    private static func parseStatuses(_ data: Data) -> [String: FileTreeStatus] {
        let records = data.split(separator: 0)
        var statuses: [String: FileTreeStatus] = [:]
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 4,
                  let value = String(data: record, encoding: .utf8) else {
                index += 1
                continue
            }

            let code = String(value.prefix(2))
            let path = String(value.dropFirst(3))
            statuses[path] = code == "??" || code.first == "A" ? .untracked : .modified

            if code.contains("R") || code.contains("C") {
                index += 1
            }
            index += 1
        }

        return statuses
    }

    static func makeTree(
        from paths: [String],
        statuses: [String: FileTreeStatus],
        rootedAt rootURL: URL
    ) -> [FileTreeItem] {
        let root = Node()

        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            var node = root

            for (index, component) in components.enumerated() {
                let isDirectory = index < components.index(before: components.endIndex)
                let child = node.children[component] ?? Node(isDirectory: isDirectory)
                child.isDirectory = child.isDirectory || isDirectory
                node.children[component] = child
                node = child
            }

            node.status = statuses[path]
        }

        return FileTreeItem.mergingContents(of: rootURL, with: root.items(at: rootURL))
    }

    private final class Node {
        var isDirectory: Bool
        var status: FileTreeStatus?
        var children: [String: Node] = [:]

        init(isDirectory: Bool = true) {
            self.isDirectory = isDirectory
        }

        func items(at directoryURL: URL) -> [FileTreeItem] {
            children.map { name, node in
                let url = directoryURL.appending(path: name, directoryHint: node.isDirectory ? .isDirectory : .notDirectory)
                if node.isDirectory {
                    let children = node.items(at: url)
                    return FileTreeItem(
                        directoryURL: url,
                        children: children,
                        status: Self.aggregateStatus(of: children)
                    )
                }
                return FileTreeItem(url: url, isDirectory: false, status: node.status)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        private static func aggregateStatus(of children: [FileTreeItem]) -> FileTreeStatus? {
            if children.contains(where: { $0.status == .modified }) {
                return .modified
            }
            if children.contains(where: { $0.status == .untracked }) {
                return .untracked
            }
            return nil
        }
    }
}

nonisolated enum WorkspaceFileIndex {
    struct Entry: Identifiable, Hashable, Sendable {
        let url: URL
        let relativePath: String
        let searchablePath: String
        let searchableFilename: String

        var id: URL { url }

        init(url: URL, relativePath: String) {
            self.url = url
            self.relativePath = relativePath
            searchablePath = relativePath.lowercased()
            searchableFilename = relativePath.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        }
    }

    static func files(in rootURL: URL) -> [Entry] {
        if let paths = GitFileTree.filePaths(in: rootURL) {
            return paths
                .map { path in
                    Entry(
                        url: rootURL.appending(path: path, directoryHint: .notDirectory),
                        relativePath: path
                    )
                }
                .sorted { $0.relativePath < $1.relativePath }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        return enumerator.compactMap { element -> Entry? in
            guard let url = element as? URL else { return nil }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                return nil
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return Entry(url: url, relativePath: relativePath(of: url, in: rootURL))
        }
        .sorted { $0.relativePath < $1.relativePath }
    }

    static func relativePath(of fileURL: URL, in rootURL: URL) -> String {
        fileURL.standardizedFileURL.pathComponents
            .dropFirst(rootURL.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }
}
