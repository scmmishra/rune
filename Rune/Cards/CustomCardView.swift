import Combine
import SwiftUI

/// Runs one custom card's source and holds what it last printed.
@MainActor
final class CustomCardModel: ObservableObject {
    @Published private(set) var content: CardContent?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    /// The space's variables, so an item that set the current values can show as selected.
    @Published private(set) var variables: [String: String] = [:]

    private var card: CustomCard
    private let root: URL
    private let branch: () -> String
    private let space: SpaceVariables
    private var observation: AnyCancellable?
    private var loop: Task<Void, Never>?
    /// A run asked for while one was going. It happens once the current one ends, so the
    /// source never runs twice at a time.
    private var isRunPending = false

    init(card: CustomCard, root: URL, space: SpaceVariables, branch: @escaping () -> String) {
        self.card = card
        self.root = root
        self.space = space
        self.branch = branch
    }

    func start() {
        guard observation == nil else { return }
        observation = space.$values.sink { [weak self] values in
            guard let self else { return }
            let previous = self.variables
            self.variables = values
            if self.card.reads.contains(where: { previous[$0] != values[$0] }) { self.run() }
        }
        run()
        schedule()
    }

    func stop() {
        observation = nil
        loop?.cancel()
        loop = nil
    }

    /// The card's file changed.
    func update(_ card: CustomCard) {
        guard card != self.card else { return }
        self.card = card
        run()
        schedule()
    }

    private func schedule() {
        loop?.cancel()
        guard observation != nil, let refresh = card.refresh else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refresh)
                guard !Task.isCancelled else { return }
                self?.run()
            }
        }
    }

    func run() {
        if let problem = card.problem {
            error = problem
            return
        }
        guard !isRunning else {
            isRunPending = true
            return
        }
        isRunning = true
        let card = card
        let root = root
        let branch = branch()
        let variables = variables
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CardSourceRunner.run(card, root: root, branch: branch, variables: variables) }
            }.value
            switch result {
            case let .success(content):
                if content != self.content { self.content = content }
                error = nil
            // A failed run keeps the last items on screen, under the reason it failed.
            case let .failure(failure): error = failure.localizedDescription
            }
            isRunning = false
            if isRunPending {
                isRunPending = false
                run()
            }
        }
    }
}

/// A custom card: its title, a refresh button, and the items its source returned.
struct CustomCardView: View {
    let card: CustomCard
    let onAction: (CardAction) -> Void
    /// Reads the card files again, so an edit to this card's file takes effect.
    let onReload: () -> Void
    @StateObject private var model: CustomCardModel
    @State private var isHovered = false

    init(card: CustomCard, root: URL, space: SpaceVariables, branch: @escaping () -> String,
         onAction: @escaping (CardAction) -> Void, onReload: @escaping () -> Void) {
        self.card = card
        self.onAction = onAction
        self.onReload = onReload
        _model = StateObject(wrappedValue: CustomCardModel(card: card, root: root, space: space, branch: branch))
    }

    private var isFill: Bool { card.sizing != .fixed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error { problem(error) }
            if let messages = model.content?.messages, !messages.isEmpty {
                CardMessageList(messages: messages, startsAtBottom: model.content?.startsAtBottom == true)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if let markdown = model.content?.markdown, !markdown.isEmpty {
                // The page scrolls itself, and a chat opens at its newest message.
                MarkdownPreview(text: markdown, isCompact: true,
                                anchor: model.content?.startsAtBottom == true ? .bottom : .top)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if isFill {
                ScrollView { rows }
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isFill ? .infinity : nil, alignment: .topLeading)
        .workspaceGroup()
        .onHover { isHovered = $0 }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: card) { model.update(card) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(card.title.uppercased())
                .sidebarSectionLabel()
                .lineLimit(1)
            Spacer(minLength: 0)
            ForEach(model.content?.buttons ?? []) { button in
                Button(button.title) { onAction(button.action) }
                    .buttonStyle(WorkspaceButtonStyle())
                    .runeFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                onReload()
                model.run()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .runeFont(size: 10, weight: .medium)
                    .rotationEffect(.degrees(model.isRunning ? 360 : 0))
                    .animation(model.isRunning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: model.isRunning)
            }
            .buttonStyle(WorkspaceButtonStyle())
            .foregroundStyle(.secondary)
            // Shown while it has something to say: on hover, and for as long as a run takes.
            .opacity(isHovered || model.isRunning ? 1 : 0)
            .help("Run the source again")
            .accessibilityLabel("Refresh \(card.title)")
        }
        .padding(.leading, WorkspaceMetrics.columnInset)
        .padding(.trailing, WorkspaceMetrics.columnInset - 4)
        .frame(height: WorkspaceMetrics.bandHeight)
    }

    private func problem(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .runeFont(size: 11)
            .foregroundStyle(ThemeColor.orange)
            .lineLimit(3)
            .padding(.horizontal, WorkspaceMetrics.columnInset)
            .padding(.bottom, 8)
            .help(message)
    }

    @ViewBuilder
    private var rows: some View {
        if let content = model.content, !content.items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(content.items) { item in
                    CustomCardRow(item: item, isSelected: isSelected(item)) {
                        if let action = item.action { onAction(action) }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        } else if model.error == nil {
            Text(model.content == nil ? "Loading…" : (model.content?.empty ?? "Nothing to show"))
                .runeFont(size: 11)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, WorkspaceMetrics.columnInset)
                .padding(.bottom, 10)
        }
    }

    /// An item is selected while the space holds every value its action sets.
    private func isSelected(_ item: CardItem) -> Bool {
        guard let values = item.action?.set, !values.isEmpty else { return false }
        return values.allSatisfy { model.variables[$0.key] == $0.value }
    }
}

private struct CustomCardRow: View {
    let item: CardItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .runeFont(size: 12)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .runeFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let badge = item.badge {
                    let tint = Self.tint(badge.tint)
                    Text(badge.text)
                        .runeFont(size: 10, weight: .medium)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBackground(isSelected: isSelected)
        // An item without an action is information, not a dimmed button.
        .allowsHitTesting(item.action != nil)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private static func tint(_ name: String?) -> ThemeColor {
        switch name?.lowercased() {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "blue": .blue
        case "yellow": .yellow
        case "purple": .purple
        default: .secondary
        }
    }
}

/// A conversation as a plain list: what was said at full strength, and who said it and
/// when held back, so the eye lands on the messages.
private struct CardMessageList: View {
    let messages: [CardMessage]
    let startsAtBottom: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if index > 0 { Divider().opacity(0.6) }
                    CardMessageRow(message: message)
                        .padding(.vertical, message.kind == .activity ? 7 : 11)
                }
            }
            .padding(.horizontal, WorkspaceMetrics.columnInset)
            .padding(.bottom, 6)
        }
        .defaultScrollAnchor(startsAtBottom ? .bottom : .top)
        .textSelection(.enabled)
    }
}

private struct CardMessageRow: View {
    let message: CardMessage

    var body: some View {
        switch message.kind {
        case .activity:
            // An event, not speech: one quiet line.
            Text([message.text, message.time].compactMap { $0 }.joined(separator: " · "))
                .runeFont(size: 11)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .message, .note:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let author = message.author {
                        Text(author).foregroundStyle(.secondary)
                    }
                    if message.kind == .note {
                        Text("Private note").foregroundStyle(.orange.opacity(0.85))
                    }
                    if let time = message.time {
                        Text(time).foregroundStyle(.tertiary)
                    }
                }
                .runeFont(size: 11)
                .lineLimit(1)
                Text(Self.body(message.text))
                    .runeFont(size: 12)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A note is set in from a rule, so it never reads as part of what was sent.
            .padding(.leading, message.kind == .note ? 10 : 0)
            .overlay(alignment: .leading) {
                if message.kind == .note {
                    Rectangle().fill(ThemeColor.orange.opacity(0.5)).frame(width: 2)
                }
            }
        }
    }

    /// Inline Markdown such as bold and links, with the message's own line breaks kept.
    private static func body(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Stands in for a card the layout names but no file defines.
struct MissingCardView: View {
    let id: WorkspaceCardID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(id.rawValue.uppercased())
                .sidebarSectionLabel()
                .frame(height: WorkspaceMetrics.bandHeight)
            Text("No card file at ~/.rune/cards/\(id.rawValue).toml. Add the file, or right-click to remove the card.")
                .runeFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, WorkspaceMetrics.columnInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceGroup()
    }
}
