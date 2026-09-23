import SwiftUI

struct ProjectSearchDrawer: View {
    @ObservedObject var model: ProjectSearchModel
    let onOpen: (ProjectSearchMatch) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var repository: GitSidebarModel
    @Environment(\.runeTypography) private var typography
    @State private var hoveredMatch: ProjectSearchMatch.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PaletteSearchField(placeholder: "Search in project", text: $model.query, isEnabled: true,
                                   onMove: moveSelection, onClose: onClose, onSubmit: openSelection)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(WorkspaceButtonStyle())
                    .runeFont(size: 11, weight: .semibold)
                    .help("Close Search (Esc)")
                    .accessibilityLabel("Close search")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 42)
            Divider()
            results
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .background { DrawerEscapeMonitor(onEscape: onClose) }
        .onChange(of: model.query) { model.search(in: repository.files) }
        .onChange(of: repository.hasLoaded) { model.search(in: repository.files, debounce: false) }
        // Search again on return so results reflect edits made from a match.
        .onAppear { model.search(in: repository.files, debounce: false) }
        .onDisappear { model.cancel() }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Group each file's matches in a card, like the commit preview's files.
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.files) { file in
                        VStack(alignment: .leading, spacing: 6) {
                            fileHeader(file)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(file.matches) { match in
                                    matchRow(match).id(match.id)
                                }
                            }
                            .padding(3)
                            .background(Color.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .overlay {
                if model.files.isEmpty, !model.isSearching {
                    Text(model.query.isEmpty ? "Search file contents across the project" : "No results for “\(model.query)”")
                        .runeFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                }
            }
            .onChange(of: model.selection, initial: true) { _, selected in
                if let selected { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    private func fileHeader(_ file: ProjectSearchFile) -> some View {
        let directory = (file.relativePath as NSString).deletingLastPathComponent
        return HStack(spacing: 7) {
            FileIconView(url: file.url, isDirectory: false)
                .frame(width: 14, height: 14)
            Text(file.url.lastPathComponent)
                .runeFont(size: 11, weight: .medium)
            if !directory.isEmpty {
                Text(directory)
                    .runeFont(size: 11)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(file.matches.count == 1 ? "1 match" : "\(file.matches.count) matches")
                .runeFont(size: 9, weight: .medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .lineLimit(1)
        .padding(.horizontal, 2)
    }

    private func matchRow(_ match: ProjectSearchMatch) -> some View {
        Button {
            model.selection = match.id
            onOpen(match)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(match.line)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
                Text(snippet(match))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .runeFont(size: 12)
            .padding(.horizontal, 8)
            .frame(minHeight: max(25, typography.size(relativeTo: 25)))
            .background {
                if model.selection == match.id {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.20))
                } else if hoveredMatch == match.id {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05))
                }
            }
            .onHover { hoveredMatch = $0 ? match.id : nil }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func snippet(_ match: ProjectSearchMatch) -> AttributedString {
        var before = AttributedString(match.before)
        before.foregroundColor = .secondary
        var found = AttributedString(match.match)
        found.backgroundColor = Color.yellow.opacity(0.35)
        var after = AttributedString(match.after)
        after.foregroundColor = .secondary
        return before + found + after
    }

    private var footer: some View {
        HStack {
            Text(summary)
            Spacer()
            QuietProgressView(isActive: model.isSearching)
            Text("↑↓ Navigate")
            Text("↩ Open")
            Text("esc Close")
        }
        .runeFont(size: 10)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var summary: String {
        guard !model.matches.isEmpty else { return "" }
        let results = model.matches.count == 1 ? "1 result" : "\(model.matches.count.formatted()) results"
        let files = model.files.count == 1 ? "1 file" : "\(model.files.count.formatted()) files"
        return model.isTruncated ? "First \(results) in \(files)" : "\(results) in \(files)"
    }

    private func moveSelection(_ direction: Int) {
        guard !model.matches.isEmpty else { return }
        let index = model.matches.firstIndex { $0.id == model.selection }
        let next = direction < 0 ? max(0, (index ?? 1) - 1) : min(model.matches.count - 1, (index ?? -1) + 1)
        model.selection = model.matches[next].id
    }

    private func openSelection() {
        guard let match = model.matches.first(where: { $0.id == model.selection }) else { return }
        onOpen(match)
    }
}
