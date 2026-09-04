import AppKit
import SwiftUI

struct ProjectPickerView: View {
    let workspaces: [WorkspaceIdentity]
    let onOpen: (WorkspaceIdentity) -> Void

    @State private var query = ""
    @State private var selectedPath: String?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.runeTypography) private var typography

    private let dialogWidth: CGFloat = 520
    private let dialogHeight: CGFloat = 400

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            VStack(spacing: 0) {
                title
                searchField
                Divider()
                projectList
                Divider()
                footer
            }
            .frame(width: dialogWidth, height: dialogHeight)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            selectedPath = matchingWorkspaces.first?.path
            isSearchFocused = true
        }
        .onChange(of: query) {
            selectedPath = matchingWorkspaces.first?.path
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { keyPress in
            moveSelection(for: keyPress.key)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open a project")
                .runeFont(size: 16, weight: .semibold)
            Text("Choose a recent project to start Rune.")
                .runeFont(size: 11)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search recent projects", text: $query)
                .textFieldStyle(.plain)
                .runeFont(size: 12)
                .focused($isSearchFocused)
                .onSubmit(openSelection)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var projectList: some View {
        if matchingWorkspaces.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Recent Projects" : "No Matches",
                systemImage: "folder",
                description: Text(
                    query.isEmpty
                        ? "Open a folder to add it to this list."
                        : "Try another project name or path."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matchingWorkspaces, id: \.path) { workspace in
                            projectRow(workspace)
                                .id(workspace.path)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedPath) { _, selectedPath in
                    if let selectedPath {
                        proxy.scrollTo(selectedPath, anchor: .center)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("↑↓ Select  ↩ Open")
                .runeFont(size: 9)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Open Other…", action: chooseFolder)
                .runeFont(size: 11, weight: .medium)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var matchingWorkspaces: [WorkspaceIdentity] {
        guard !query.isEmpty else { return workspaces }
        let normalizedQuery = Array(query.lowercased().utf8)
        var matches: [(workspace: WorkspaceIdentity, score: Int)] = []

        for workspace in workspaces {
            guard let score = FuzzyMatcher.pathScore(
                normalizedQuery,
                path: workspace.path.lowercased(),
                filename: workspace.name.lowercased()
            ) else { continue }
            matches.append((workspace, score))
        }

        matches.sort { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.workspace.name < rhs.workspace.name
                : lhs.score > rhs.score
        }
        return matches.map(\.workspace)
    }

    private func projectRow(_ workspace: WorkspaceIdentity) -> some View {
        Button {
            onOpen(workspace)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .runeFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                    Text(workspace.path)
                        .runeFont(size: 9)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: max(42, typography.size(relativeTo: 42)))
            .contentShape(Rectangle())
            .background {
                if selectedPath == workspace.path {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.16))
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture().onEnded {
                selectedPath = workspace.path
            }
        )
    }

    private func openSelection() {
        guard let selectedPath,
              let workspace = matchingWorkspaces.first(where: { $0.path == selectedPath })
        else { return }
        onOpen(workspace)
    }

    private func moveSelection(for key: KeyEquivalent) -> KeyPress.Result {
        let matches = matchingWorkspaces
        guard !matches.isEmpty else { return .ignored }
        let currentIndex = selectedPath.flatMap { path in
            matches.firstIndex { $0.path == path }
        }

        if key == .upArrow {
            selectedPath = matches[max(0, (currentIndex ?? 1) - 1)].path
            return .handled
        }
        if key == .downArrow {
            selectedPath = matches[min(matches.count - 1, (currentIndex ?? -1) + 1)].path
            return .handled
        }
        return .ignored
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let url = panel.url,
              let workspace = WorkspaceIdentity(url: url)
        else { return }
        onOpen(workspace)
    }
}
