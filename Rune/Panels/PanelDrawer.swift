import AppKit
import SwiftUI

/// A panel from `~/.rune/panels`, drawn with native controls in the workspace drawer.
struct PanelDrawer: View {
    @StateObject private var model: PanelModel
    let onEditFile: (URL) -> Void
    let onClose: () -> Void

    init(definition: PanelDefinition, rootURL: URL, onEditFile: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PanelModel(definition: definition, rootURL: rootURL))
        self.onEditFile = onEditFile
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let problem = model.setupProblem {
                ContentUnavailableView {
                    Label("Panel Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem).textSelection(.enabled)
                } actions: {
                    Button("Edit Panel File") { onEditFile(model.definition.fileURL) }
                }
            } else if let detail = model.detail {
                PanelDetailView(model: model, detail: detail)
            } else if model.rootName == nil {
                // A route is still choosing the view.
                QuietProgressView(isActive: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelListView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .background { DrawerEscapeMonitor(onEscape: escape) }
        .task { await model.start() }
        .task(id: model.rootView?.refresh) {
            guard let interval = model.rootView?.refresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                model.refreshInBackground()
            }
        }
        .onDisappear { model.stop() }
        .alert(
            model.confirming?.action.confirm ?? "",
            isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }),
            presenting: model.confirming
        ) { pending in
            Button(pending.action.title) { model.run(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(PanelTemplate.display(pending.arguments))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let detail = model.detail, !detail.isRoot {
                Button(action: model.closeDetail) { Image(systemName: "chevron.left") }
                    .buttonStyle(WorkspaceButtonStyle())
                    .help("Back (Esc)")
                    .accessibilityLabel("Back")
            }
            Image(systemName: model.definition.icon)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
            Text(model.detail.map(model.title(of:)) ?? model.definition.title)
                .runeFont(size: 12, weight: .medium)
                .lineLimit(1)
            QuietProgressView(isActive: model.isLoading || model.detail?.isLoading == true)
            Spacer()
            Button {
                if model.detail == nil { model.reload(silently: true) } else { model.loadDetail() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(WorkspaceButtonStyle())
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .disabled(model.setupProblem != nil)
            Button { onEditFile(model.definition.fileURL) } label: { Image(systemName: "pencil") }
                .buttonStyle(WorkspaceButtonStyle())
                .help("Edit Panel File")
                .accessibilityLabel("Edit panel file")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(WorkspaceButtonStyle())
                .help("Close Panel (Esc)")
                .accessibilityLabel("Close panel")
        }
        .runeFont(size: 11, weight: .semibold)
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    /// Escape backs out one step at a time: the reply box, then the item, then the panel.
    private func escape() {
        if model.prompting != nil {
            model.prompting = nil
        } else if let detail = model.detail, !detail.isRoot {
            model.closeDetail()
        } else {
            onClose()
        }
    }
}

// MARK: - List

private struct PanelListView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.definition.inputs.isEmpty {
                PanelInputBar(model: model)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.items) { item in
                        PanelRow(item: item, badges: model.rootView?.item?.badges ?? [],
                                 isOpenable: model.rootView?.item?.open != nil) {
                            model.open(item)
                        }
                        .onAppear { if item.id == model.items.last?.id { model.loadMore() } }
                    }
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small).padding(10)
                    }
                }
                .padding(6)
            }
            .overlay {
                if let error = model.error, model.items.isEmpty {
                    PanelMessageView(text: error, systemImage: "exclamationmark.triangle", retry: { model.reload() })
                } else if model.items.isEmpty, !model.isLoading {
                    let empty = model.rootView?.empty.map {
                        PanelTemplate.render($0, context: .object(model.values.mapValues(PanelValue.string))).text
                    }
                    PanelMessageView(text: empty ?? "Nothing to show", systemImage: nil, retry: nil)
                }
            }
            if let error = model.error, !model.items.isEmpty {
                Divider()
                Text(error)
                    .runeFont(size: 11)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }
}

private struct PanelInputBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.definition.inputs) { input in
                    control(for: input)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .controlSize(.small)
        .runeFont(size: 11)
    }

    private func binding(for input: PanelInput) -> Binding<String> {
        Binding(get: { model.value(for: input) }, set: { model.set(input, to: $0) })
    }

    @ViewBuilder
    private func control(for input: PanelInput) -> some View {
        let name = input.label ?? input.id.capitalized
        switch input.kind {
        case .segmented:
            Picker(name, selection: binding(for: input)) {
                ForEach(model.options(for: input), id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .menu:
            let options = model.options(for: input)
            let selected = options.first { $0.value == model.value(for: input) }
            Menu {
                if input.isOptional {
                    Button("Any \(name)") { model.set(input, to: "") }
                    Divider()
                }
                ForEach(options, id: \.value) { option in
                    Button(option.label) { model.set(input, to: option.value) }
                }
            } label: {
                Text(selected.map { "\(name): \($0.label)" } ?? name)
            }
            .menuStyle(.button)
            .fixedSize()
        case .search:
            TextField(name, text: binding(for: input), prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }
}

private struct PanelRow: View {
    let item: PanelItem
    let badges: [PanelViewSpec.Badge]
    let isOpenable: Bool
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(item.isUnread ? 1 : 0)
                    .padding(.top, 6)
                    .accessibilityHidden(!item.isUnread)
                    .accessibilityLabel("Unread")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .runeFont(size: 12, weight: item.isUnread ? .semibold : .medium)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let trailing = item.trailing {
                            Text(trailing)
                                .runeFont(size: 11)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .runeFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !item.badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(item.badges, id: \.self) { badge in
                                PanelBadgeView(text: badge.text, color: tint(of: badge))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(isHovered && isOpenable ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOpenable)
        .onHover { isHovered = $0 }
    }

    private func tint(of badge: PanelBadge) -> Color {
        guard badges.indices.contains(badge.rule) else { return .secondary }
        let rule = badges[badge.rule]
        return PanelBadgeView.color(named: rule.tints[badge.text] ?? rule.tint)
    }
}

private struct PanelBadgeView: View {
    let text: String
    let color: Color

    static func color(named name: String?) -> Color {
        switch name?.lowercased() {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        default: .secondary
        }
    }

    var body: some View {
        Text(text)
            .runeFont(size: 10, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

private struct PanelMessageView: View {
    let text: String
    let systemImage: String?
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            Text(text)
                .runeFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let retry {
                Button("Try Again", action: retry).controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

// MARK: - Detail

private struct PanelDetailView: View {
    @ObservedObject var model: PanelModel
    let detail: PanelModel.Detail

    var body: some View {
        VStack(spacing: 0) {
            let actions = model.visibleActions(in: detail)
            if !actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(actions) { action in
                            Button { model.trigger(action) } label: {
                                HStack(spacing: 4) {
                                    if model.runningAction == action.id {
                                        ProgressView().controlSize(.mini)
                                    } else if let icon = action.icon {
                                        Image(systemName: icon)
                                    }
                                    Text(action.title)
                                }
                            }
                            .disabled(model.runningAction != nil)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .controlSize(.small)
                .runeFont(size: 11)
                Divider()
            }

            Group {
                if let error = detail.error {
                    PanelMessageView(text: error, systemImage: "exclamationmark.triangle", retry: model.loadDetail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let markdown = detail.markdown {
                    MarkdownPreview(text: markdown)
                } else if detail.view.body?.kind == .thread {
                    if detail.messages.isEmpty, detail.hasLoaded {
                        PanelMessageView(text: detail.view.empty ?? "Nothing here yet", systemImage: nil, retry: nil)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PanelThreadView(messages: detail.messages)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = model.actionError {
                Divider()
                Text(error)
                    .runeFont(size: 11)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            if let action = model.prompting {
                Divider()
                PanelComposer(model: model, action: action)
            }
        }
    }
}

private struct PanelThreadView: View {
    let messages: [PanelMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        VStack(alignment: message.isTrailing ? .trailing : .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if let author = message.author { Text(author).runeFont(size: 10, weight: .semibold) }
                                if let time = message.time { Text(time).runeFont(size: 10) }
                                if message.isMuted { Image(systemName: "lock").imageScale(.small) }
                            }
                            .foregroundStyle(.secondary)
                            Text(Self.formatted(message.text))
                                .runeFont(size: 12)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(bubble(for: message), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .opacity(message.isMuted ? 0.75 : 1)
                        }
                        .frame(maxWidth: 520, alignment: message.isTrailing ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: message.isTrailing ? .trailing : .leading)
                        .id(message.id)
                    }
                }
                .padding(16)
            }
            // Conversations read bottom-up: open on the newest message.
            .onChange(of: messages.count, initial: true) {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Inline Markdown such as links, code and emphasis; the text shows as written otherwise.
    private static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func bubble(for message: PanelMessage) -> Color {
        if message.isMuted { return Color.yellow.opacity(0.14) }
        return message.isTrailing ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)
    }
}

private struct PanelComposer: View {
    @ObservedObject var model: PanelModel
    let action: PanelAction
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.promptText.isEmpty {
                    Text(action.prompt?.placeholder.map { PanelTemplate.render($0, context: placeholderContext).text } ?? action.title)
                        .runeFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.promptText)
                    .runeFont(size: 12)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
            }
            .frame(height: action.prompt?.isMultiline == false ? 22 : 80)
            HStack {
                Text("⌘↩ to send").runeFont(size: 10).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.prompting = nil }
                Button(action.title, action: model.submitPrompt)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.runningAction != nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .onAppear { isFocused = true }
    }

    private var placeholderContext: PanelValue {
        .object(["item": model.detail?.item.raw ?? .null])
    }
}
