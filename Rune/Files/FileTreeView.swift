import SwiftUI

struct FileTreeView: View {
    let rootURL: URL

    var body: some View {
        FileTreeContents(rootURL: rootURL)
            .id(rootURL)
    }
}

private struct FileTreeContents: View {
    let rootURL: URL
    @State private var items: [FileTreeItem]
    @State private var expandedDirectories: Set<URL>

    init(rootURL: URL) {
        self.rootURL = rootURL
        _items = State(initialValue: FileTreeItem.workspaceContents(of: rootURL))
        _expandedDirectories = State(initialValue: [])
    }

    var body: some View {
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
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, 52)
    }

    private var visibleItems: [VisibleFileTreeItem] {
        flattened(items, depth: 0)
    }

    private func flattened(_ items: [FileTreeItem], depth: Int) -> [VisibleFileTreeItem] {
        items.flatMap { item in
            var result = [VisibleFileTreeItem(item: item, depth: depth)]
            if item.isDirectory,
               expandedDirectories.contains(item.url),
               let children = item.children {
                result.append(contentsOf: flattened(children, depth: depth + 1))
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

            Image(systemName: FileTreeIcon.symbolName(for: url, isDirectory: isDirectory))
                .font(.system(size: 10))
                .foregroundStyle(status?.color ?? Color.secondary)
                .frame(width: 12)

            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(status?.color ?? Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 10)
        .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isDirectory else { return }
            if expandedDirectories.contains(url) {
                expandedDirectories.remove(url)
            } else {
                expandedDirectories.insert(url)
            }
        }
    }
}

private struct VisibleFileTreeItem: Identifiable {
    let item: FileTreeItem
    let depth: Int

    var id: URL { item.id }
}

private final class FileTreeItem: Identifiable {
    let url: URL
    let isDirectory: Bool
    let status: FileTreeStatus?
    private let loadChildren: (() -> [FileTreeItem])?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    lazy var children: [FileTreeItem]? = loadChildren?()

    init(url: URL, isDirectory: Bool, status: FileTreeStatus? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.status = status
        loadChildren = isDirectory ? { Self.contents(of: url) } : nil
    }

    init(directoryURL: URL, children: [FileTreeItem], status: FileTreeStatus?) {
        url = directoryURL
        isDirectory = true
        self.status = status
        loadChildren = { children }
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
}

private enum FileTreeStatus: Equatable {
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

private enum FileTreeIcon {
    static func symbolName(for url: URL, isDirectory: Bool) -> String {
        if isDirectory {
            return "folder.fill"
        }

        switch url.lastPathComponent.lowercased() {
        case ".gitignore", ".gitattributes", ".gitmodules":
            return "arrow.triangle.branch"
        case "license", "license.md", "copying":
            return "checkmark.seal"
        case "makefile", "dockerfile":
            return "hammer"
        default:
            break
        }

        switch url.pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "sh", "bash", "zsh", "fish":
            return "terminal"
        case "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "rb", "py", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "rtf":
            return "doc.text"
        case "json", "jsonc", "plist", "yaml", "yml", "toml", "xml":
            return "curlybraces"
        case "xcodeproj", "xcworkspace":
            return "hammer.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo"
        case "zip", "gz", "tar", "tgz", "bz2", "xz":
            return "archivebox"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

private enum GitFileTree {
    static func contents(of directoryURL: URL) -> [FileTreeItem]? {
        guard let files = runGit(
            ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            in: directoryURL
        ) else {
            return nil
        }

        let paths = files.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        let statusData = runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no"],
            in: directoryURL
        )
        let statuses = statusData.map(parseStatuses) ?? [:]
        return makeTree(from: paths, statuses: statuses, rootedAt: directoryURL)
    }

    private static func runGit(_ arguments: [String], in directoryURL: URL) -> Data? {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directoryURL.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

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

    private static func makeTree(
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

        return root.items(at: rootURL)
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
