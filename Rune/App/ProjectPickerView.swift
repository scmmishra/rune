import SwiftUI

struct ProjectPickerView: View {
    let workspaces: [WorkspaceIdentity]
    /// Named arrangements, each opening its own repository in a window of its own.
    var setups: [WorkspaceSetup] = []
    let onClose: () -> Void
    let onOpen: (WorkspaceIdentity) -> Void
    let onChooseDirectory: () -> Void
    @State private var query = ""
    @State private var selection: Entry.ID?

    private struct Entry: Identifiable {
        enum Kind {
            case project(WorkspaceIdentity)
            case setup(WorkspaceSetup)
            case chooseDirectory
        }

        let kind: Kind

        var id: String {
            switch kind {
            case let .project(workspace): "project:" + workspace.path
            case let .setup(setup): "setup:" + setup.id
            case .chooseDirectory: "choose-directory"
            }
        }

        /// What the query is matched against: a folder's path, or a setup's name and repository.
        var searchText: (path: String, name: String) {
            switch kind {
            case let .project(workspace): (workspace.path.lowercased(), workspace.name.lowercased())
            case let .setup(setup): ((setup.repositoryName + " " + setup.name).lowercased(), setup.name.lowercased())
            case .chooseDirectory: ("", "")
            }
        }
    }

    private var entries: [Entry] {
        let all = setups.map { Entry(kind: .setup($0)) } + workspaces.map { Entry(kind: .project($0)) }
        let matches: [Entry]
        if query.isEmpty {
            // Recent projects first, as before; setups follow them.
            matches = workspaces.map { Entry(kind: .project($0)) } + setups.map { Entry(kind: .setup($0)) }
        } else {
            let bytes = Array(query.lowercased().utf8)
            matches = all.compactMap { entry -> (Entry, Int)? in
                let text = entry.searchText
                guard let score = FuzzyMatcher.pathScore(bytes, path: text.path, filename: text.name) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
            .map(\.0)
        }
        // Keep the directory action reachable even when no recent project matches.
        return matches + [Entry(kind: .chooseDirectory)]
    }

    var body: some View {
        SearchPalette(
            placeholder: "Open project", query: $query, items: entries,
            selection: $selection, onClose: onClose, onSelect: { entry in
                switch entry.kind {
                case let .project(workspace): onOpen(workspace)
                case let .setup(setup): if let workspace = WorkspaceIdentity(setup: setup) { onOpen(workspace) }
                case .chooseDirectory: onChooseDirectory()
                }
            }
        ) { entry in
            HStack(spacing: 8) {
                switch entry.kind {
                case let .project(workspace):
                    icon("folder")
                    Text(workspace.name).lineLimit(1)
                    Text(workspace.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case let .setup(setup):
                    icon(WorkspaceSetup.symbol)
                    Text(setup.name).lineLimit(1)
                    Text(setup.repositoryName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .chooseDirectory:
                    icon("folder.badge.plus")
                    Text("Choose Directory…")
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { selection = entries.first?.id }
        .onChange(of: query) { selection = entries.first?.id }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 12)
    }
}

extension WorkspaceSetup {
    static let symbol = "rectangle.3.group"
}
