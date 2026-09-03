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

            Image(systemName: isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(name)
                .font(.system(size: 12, design: .monospaced))
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
    private let loadChildren: (() -> [FileTreeItem])?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    lazy var children: [FileTreeItem]? = loadChildren?()

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        loadChildren = isDirectory ? { Self.contents(of: url) } : nil
    }

    init(directoryURL: URL, children: [FileTreeItem]) {
        url = directoryURL
        isDirectory = true
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

private enum GitFileTree {
    static func contents(of directoryURL: URL) -> [FileTreeItem]? {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", directoryURL.path,
            "ls-files", "--cached", "--others", "--exclude-standard", "-z"
        ]
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

        let paths = data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        return makeTree(from: paths, rootedAt: directoryURL)
    }

    private static func makeTree(from paths: [String], rootedAt rootURL: URL) -> [FileTreeItem] {
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
        }

        return root.items(at: rootURL)
    }

    private final class Node {
        var isDirectory: Bool
        var children: [String: Node] = [:]

        init(isDirectory: Bool = true) {
            self.isDirectory = isDirectory
        }

        func items(at directoryURL: URL) -> [FileTreeItem] {
            children.map { name, node in
                let url = directoryURL.appending(path: name, directoryHint: node.isDirectory ? .isDirectory : .notDirectory)
                if node.isDirectory {
                    return FileTreeItem(directoryURL: url, children: node.items(at: url))
                }
                return FileTreeItem(url: url, isDirectory: false)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
