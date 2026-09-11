import AppKit
import SwiftUI

enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case reload, openProject, switchBranch, hideTerminal, changeGuide, showWelcome

    var id: Self { self }

    var shortcutLabel: String? {
        switch self {
        case .openProject: "⇧⌘O"
        case .switchBranch: "⇧⌘B"
        case .reload, .hideTerminal, .changeGuide, .showWelcome: nil
        }
    }

    var title: String {
        switch self {
        case .changeGuide: "Show Change Brief…"
        case .reload: "Reload Files and Git"
        case .openProject: "Open Project…"
        case .switchBranch: "Switch Branch…"
        case .hideTerminal: "Hide Secondary Terminal"
        case .showWelcome: "Show Welcome…"
        }
    }
    var symbol: String {
        switch self {
        case .changeGuide: "sparkles"
        case .reload: "arrow.clockwise"
        case .openProject: "folder"
        case .switchBranch: "arrow.triangle.branch"
        case .hideTerminal: "rectangle.righthalf.inset.filled"
        case .showWelcome: "hand.wave"
        }
    }
}

struct CommandPalette: View {
    let canSwitchBranch: Bool
    let canHideTerminal: Bool
    let rootURL: URL
    let canShowGuide: Bool
    @ObservedObject var guide: ChangeGuideModel
    let onSelectGuide: (GuideScope) -> Void
    @ObservedObject var terminals: TerminalSessions
    let onClose: () -> Void
    let onSelect: (WorkspaceCommand) -> Void
    let onSelectTerminal: (TerminalSession) -> Void
    @State private var choosingGuideScope = false
    @State private var guideBranches: GitGuideBranches?
    @State private var query = ""
    @State private var selection: Entry.ID? = "command:reload"

    private enum Entry: Identifiable {
        case scope(GuideScope)
        case command(WorkspaceCommand)
        case terminal(TerminalSession)

        var id: String {
            switch self {
            case let .scope(scope): "scope:" + scope.rawValue
            case let .command(command): "command:" + command.rawValue
            case let .terminal(session): "terminal:" + session.id.uuidString
            }
        }

        var title: String {
            switch self {
            case let .scope(scope): scope.rawValue
            case let .command(command): command.title
            case let .terminal(session): "Switch to \(session.name)"
            }
        }

        var symbol: String {
            switch self {
            case .scope: "arrow.triangle.branch"
            case let .command(command): command.symbol
            case .terminal: "terminal"
            }
        }
    }

    private var prDescription: String {
        guard let branches = guideBranches else { return "Checking branch…" }
        guard branches.allowsPR else { return "Requires a non-default branch" }
        let comparison = guide.comparisonBranch.isEmpty ? branches.comparison : guide.comparisonBranch
        return "Compare against " + comparison
    }

    private var matches: [Entry] {
        let commands: [Entry] = choosingGuideScope ? GuideScope.allCases.map(Entry.scope) : WorkspaceCommand.allCases
            .filter { $0 != .changeGuide || canShowGuide }
            .filter { $0 != .switchBranch || canSwitchBranch }
            .filter { $0 != .hideTerminal || canHideTerminal }
            .map(Entry.command) + terminals.all.map(Entry.terminal)
        guard !query.isEmpty else { return commands }
        let bytes = Array(query.lowercased().utf8)
        return commands.compactMap { command -> (Entry, Int)? in
            let name = command.title.lowercased()
            guard let score = FuzzyMatcher.pathScore(bytes, path: name, filename: name) else { return nil }
            return (command, score)
        }
        .sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }
        .map(\.0)
    }

    var body: some View {
        SearchPalette(
            placeholder: choosingGuideScope ? "Change Brief: choose changes" : "Run a command", query: $query, items: matches,
            selection: $selection, isEnabled: { entry in
                if case .scope(.pr) = entry { return guideBranches?.allowsPR == true }
                return true
            }, onClose: onClose, onSelect: { entry in
                switch entry {
                case .command(.changeGuide) where !guide.isGenerating:
                    choosingGuideScope = true
                    query = ""
                    selection = "scope:" + (guide.scope == .pr && guideBranches?.allowsPR != true ? GuideScope.workingTree : guide.scope).rawValue
                case let .scope(scope): onSelectGuide(scope)
                case let .command(command): onSelect(command)
                case let .terminal(session): onSelectTerminal(session)
                }
            }
        ) { command in
            HStack(spacing: 8) {
                Image(systemName: command.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                Text(command.title)
                Spacer(minLength: 0)
                if case .scope(.pr) = command {
                    Text(prDescription)
                        .foregroundStyle(.secondary)
                }
                if case let .command(workspaceCommand) = command,
                   let shortcut = workspaceCommand.shortcutLabel {
                    Text(shortcut).foregroundStyle(.secondary)
                }
                if case let .terminal(session) = command,
                   let number = terminals.navigation.shortcutNumber(for: session.id) {
                    Text("⌘\(number)").foregroundStyle(.secondary)
                } else if case let .terminal(session) = command, session.id == terminals.primary.id {
                    Text("⌘`").foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guideBranches = await Task.detached(priority: .utility) {
                GitRepository.guideBranches(at: rootURL)
            }.value
        }
        .onChange(of: query) { selection = matches.first?.id }
        .onChange(of: canSwitchBranch) { selection = matches.first?.id }
        .onChange(of: canHideTerminal) { selection = matches.first?.id }
        .onChange(of: terminals.supporting.map(\.id)) {
            if !matches.contains(where: { $0.id == selection }) { selection = matches.first?.id }
        }
    }
}

struct QuickOpenPanel: View {
    let rootURL: URL
    let onOpen: (URL) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var repository: GitSidebarModel

    @State private var query = ""
    @State private var files: [WorkspaceFileIndex.Entry] = []
    @State private var matchingFiles: [WorkspaceFileIndex.Entry] = []
    @State private var isLoading = true
    @State private var selectedURL: URL?
    @State private var searchTask: Task<Void, Never>?

    // Bound SwiftUI diffing while still keeping far more results than the panel can display.
    private let resultLimit = 200

    var body: some View {
        SearchPalette(
            placeholder: "Open file", query: $query, items: matchingFiles,
            selection: $selectedURL, isLoading: isLoading,
            onClose: onClose, onSelect: { onOpen($0.url) }
        ) { file in
            HStack(spacing: 8) {
                FileIconView(url: file.url, isDirectory: false)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .onChange(of: query) {
            refreshMatches()
        }
        .onChange(of: repository.files, initial: true) {
            files = repository.files
            isLoading = !repository.hasLoaded
            refreshMatches()
        }
        .onChange(of: repository.hasLoaded) { isLoading = !repository.hasLoaded }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func refreshMatches() {
        searchTask?.cancel()

        let query = query
        let files = files
        guard !query.isEmpty else {
            matchingFiles = Array(files.prefix(resultLimit))
            selectedURL = matchingFiles.first?.url
            return
        }

        let worker = Task.detached(priority: .userInitiated) {
            QuickOpenSearch.matches(query: query, files: files, limit: resultLimit)
        }

        searchTask = Task {
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, self.query == query else { return }
            matchingFiles = matches
            selectedURL = matches.first?.url
        }
    }
}

nonisolated private enum QuickOpenSearch {
    static func matches(
        query: String,
        files: [WorkspaceFileIndex.Entry],
        limit: Int
    ) -> [WorkspaceFileIndex.Entry] {
        let normalizedQuery = Array(query.lowercased().utf8)
        var matches: [(file: WorkspaceFileIndex.Entry, score: Int)] = []
        matches.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled {
                return []
            }

            guard let score = FuzzyMatcher.pathScore(
                normalizedQuery,
                path: file.searchablePath,
                filename: file.searchableFilename
            ) else { continue }
            matches.append((file, score))
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.file.relativePath < rhs.file.relativePath
        }

        return matches.prefix(limit).map(\.file)
    }
}

struct SearchPalette<Item: Identifiable, Row: View>: View {
    let placeholder: String
    @Binding var query: String
    let items: [Item]
    @Binding var selection: Item.ID?
    var isLoading = false
    var isBusy = false
    var error: String?
    var isEnabled: (Item) -> Bool = { _ in true }
    let onClose: () -> Void
    let onSelect: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row
    @Environment(\.runeTypography) private var typography
    @State private var hoveredItem: Item.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PaletteSearchField(placeholder: placeholder, text: $query, isEnabled: !isBusy,
                    onMove: moveSelection, onClose: onClose, onSubmit: {
                        guard !isBusy, let item = items.first(where: { $0.id == selection }), isEnabled(item) else { return }
                        onSelect(item)
                    })
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                guard !isBusy, isEnabled(item) else { return }
                                selection = item.id
                                onSelect(item)
                            } label: {
                                row(item)
                                    .runeFont(size: 12)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: max(25, typography.size(relativeTo: 25)))
                                    .background {
                                        if selection == item.id {
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(Color.accentColor.opacity(0.20))
                                        } else if hoveredItem == item.id {
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(Color.primary.opacity(0.05))
                                        }
                                    }
                                    .onHover { hoveredItem = $0 ? item.id : nil }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy || !isEnabled(item))
                            .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .overlay {
                    if items.isEmpty, !isLoading, !isBusy, error == nil {
                        Text(query.isEmpty ? "Nothing to show yet" : "No results for “\(query)”")
                            .runeFont(size: 12)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(20)
                    }
                    QuietProgressView(isActive: isLoading || isBusy)
                }
                .onChange(of: selection) { _, selected in
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
            Divider()
            HStack {
                Text("↑↓ Navigate")
                Spacer()
                Text("↩ Select")
                Text("esc Close")
            }
            .runeFont(size: 10)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            if let error {
                Divider()
                Text(error)
                    .runeFont(size: 11)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
    }

    private func moveSelection(_ direction: Int) {
        let enabledItems = items.filter(isEnabled)
        guard !isBusy, !enabledItems.isEmpty else { return }
        let index = selection.flatMap { selected in enabledItems.firstIndex { $0.id == selected } }
        let next = direction < 0 ? max(0, (index ?? 1) - 1) : min(enabledItems.count - 1, (index ?? -1) + 1)
        selection = enabledItems[next].id
    }
}

private struct PaletteSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isEnabled: Bool
    let onMove: (Int) -> Void
    let onClose: () -> Void
    let onSubmit: () -> Void
    @Environment(\.runeTypography) private var typography

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        context.coordinator.install(for: field)
        return field
    }

    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.font = typography.nsFont(size: 13)
        if field.stringValue != text { field.stringValue = text }
        let wasEnabled = field.isEnabled
        field.isEnabled = isEnabled
        if !wasEnabled, isEnabled { field.window?.makeFirstResponder(field) }
    }

    static func dismantleNSView(_ field: SearchField, coordinator: Coordinator) {
        field.restorePreviousFocus()
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        field.delegate = nil
    }

    final class SearchField: NSTextField {
        private weak var previousResponder: NSView?
        private var previousSelection: NSRange?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled else { return }
                guard let window = self.window else { return }
                // AppKit reuses one field editor across text fields. Save its owner,
                // not the editor itself, so dismissal restores the correct control.
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                    self.previousResponder = editor.delegate as? NSView
                    self.previousSelection = editor.selectedRange()
                } else {
                    self.previousResponder = window.firstResponder as? NSView
                }
                window.makeFirstResponder(self)
            }
        }

        func restorePreviousFocus() {
            guard let window, let previousResponder,
                  previousResponder.window === window,
                  window.firstResponder === currentEditor() || window.firstResponder === self
            else { return }
            // Do not steal focus if the user has already clicked another control.
            if window.makeFirstResponder(previousResponder),
               let selection = previousSelection,
               let editor = (previousResponder as? NSTextField)?.currentEditor() as? NSTextView {
                editor.setSelectedRange(selection)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        var monitor: Any?
        private var consumedEscape = false

        init(parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            if parent.isEnabled { parent.onSubmit() }
            return true
        }

        func install(for field: NSTextField) {
            // The field editor can swallow SwiftUI repeat events. Consume native key-downs,
            // including auto-repeat, only while this palette's search field owns focus.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak field] event in
                guard let self, let field, let window = field.window,
                      event.window === window, let editor = field.currentEditor(),
                      window.firstResponder === editor,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                else { return event }

                switch event.keyCode {
                case 125, 126:
                    if event.type == .keyDown, self.parent.isEnabled {
                        self.parent.onMove(event.keyCode == 126 ? -1 : 1)
                    }
                    return nil
                case 53:
                    if event.type == .keyDown { self.consumedEscape = true }
                    if event.type == .keyUp, self.consumedEscape {
                        self.consumedEscape = false
                        if self.parent.isEnabled { self.parent.onClose() }
                    }
                    return nil
                default: return event
                }
            }
        }
    }
}
