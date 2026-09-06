import SwiftUI

struct ProjectPickerView: View {
    let workspaces: [WorkspaceIdentity]
    let onClose: () -> Void
    let onOpen: (WorkspaceIdentity) -> Void
    let onChooseDirectory: () -> Void
    @State private var query = ""
    @State private var selection: Entry.ID?

    private struct Entry: Identifiable {
        let workspace: WorkspaceIdentity?
        var id: String { workspace.map { "project:" + $0.path } ?? "choose-directory" }
    }

    private var entries: [Entry] {
        let matches: [WorkspaceIdentity]
        if query.isEmpty {
            matches = workspaces
        } else {
            let bytes = Array(query.lowercased().utf8)
            matches = workspaces.compactMap { workspace -> (WorkspaceIdentity, Int)? in
                guard let score = FuzzyMatcher.pathScore(
                    bytes, path: workspace.path.lowercased(), filename: workspace.name.lowercased()
                ) else { return nil }
                return (workspace, score)
            }
            .sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
            .map(\.0)
        }
        // Keep the directory action reachable even when no recent project matches.
        return matches.map { Entry(workspace: $0) } + [Entry(workspace: nil)]
    }

    var body: some View {
        SearchPalette(
            placeholder: "Open project", query: $query, items: entries,
            selection: $selection, onClose: onClose, onSelect: { entry in
                if let workspace = entry.workspace { onOpen(workspace) }
                else { onChooseDirectory() }
            }
        ) { entry in
            HStack(spacing: 8) {
                Image(systemName: entry.workspace == nil ? "folder.badge.plus" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                if let workspace = entry.workspace {
                    Text(workspace.name).lineLimit(1)
                    Text(workspace.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Choose Directory…")
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { selection = entries.first?.id }
        .onChange(of: query) { selection = entries.first?.id }
    }
}
