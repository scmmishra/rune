import AppKit
import SwiftUI

/// A pretend workspace driven by the real `TerminalNavigation` and `TerminalHoldGesture`,
/// so every shortcut on the terminals step behaves exactly as it will in the app.
@MainActor
final class OnboardingTerminalDemo: ObservableObject {
    struct Session: Identifiable {
        let id = UUID()
        let name: String
        let line: String
    }

    enum Lesson: String, CaseIterable, Identifiable {
        case select, holdPeek, peekLast, open, cycle, main
        var id: Self { self }

        var title: String {
            switch self {
            case .select: "Switch terminal"
            case .holdPeek: "Peek while held"
            case .peekLast: "Peek last terminal"
            case .open: "Open the peek"
            case .cycle: "Previous / next"
            case .main: "Back to main"
            }
        }

        var keys: [String] {
            switch self {
            case .select: ["⌘", "1–4"]
            case .holdPeek: ["hold", "⌘", "2–4"]
            case .peekLast: ["⌘", "D"]
            case .open: ["↩"]
            case .cycle: ["⌥", "⌘", "↑↓"]
            case .main: ["⌘", "`"]
            }
        }
    }

    let sessions = [
        Session(name: "Main", line: "~/code/api ❯ git status"),
        Session(name: "Claude Code", line: "✻ Editing Sources/Routes.swift…"),
        Session(name: "Codex", line: "▸ Running the test suite"),
        Session(name: "tests", line: "✓ 142 passed in 3.1s"),
    ]

    @Published private(set) var navigation: TerminalNavigation
    @Published private(set) var learned: Set<Lesson> = []
    @Published private(set) var caption = "Try the shortcuts below. Nothing here touches a real terminal."
    @Published private(set) var isCommandHeld = false

    private var hold = TerminalHoldGesture()
    private var holdTask: Task<Void, Never>?
    private var holdPeekID: UUID?
    private var recentPeekID: UUID?
    /// The fresh peek Return would open, as in the workspace.
    private var armedID: UUID?
    /// Two previews fit the illustration; the app allows more.
    private let peekLimit = 2

    init() {
        navigation = TerminalNavigation(primaryID: sessions[0].id)
        sessions.dropFirst().forEach { navigation.add($0.id) }
        // Start with some history so ⌘D has a "last terminal" to show.
        navigation.select(sessions[1].id)
        navigation.select(sessions[0].id)
    }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    /// Returns true when the event was used by the demo.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            isCommandHeld = event.modifierFlags.contains(.command)
            if !isCommandHeld { finish(hold.releaseCommand()) }
            return false
        case .keyUp:
            guard let outcome = hold.release(keyCode: event.keyCode) else { return false }
            finish(outcome)
            return true
        case .keyDown:
            return keyDown(event)
        default:
            return false
        }
    }

    private func keyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Return (with or without ⌘) opens a fresh peek; otherwise it stays Continue.
        if event.keyCode == 36 || event.keyCode == 76, modifiers.isSubset(of: .command),
           let id = armedID, navigation.isPeeked(id) {
            armedID = nil
            holdPeekID = nil
            animate { navigation.select(id) }
            learn(.open, "Opened \(name(id)) in the panel")
            return true
        }
        if event.keyCode == 53, modifiers.isEmpty, let id = navigation.peekedIDs.last {
            close(id)
            caption = "Escape put the peek away"
            return true
        }
        guard let shortcut = TerminalShortcut.matching(event) else { return false }
        guard !event.isARepeat else { return true }
        switch shortcut {
        case let .select(number):
            finish(hold.releaseCommand())
            let token = hold.press(number: number, keyCode: event.keyCode)
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: TerminalHoldGesture.threshold)
                guard !Task.isCancelled, let self else { return }
                self.finish(self.hold.expire(token: token))
            }
        case let .peek(number):
            guard let id = sessionID(number), id != navigation.primaryID else { break }
            peek(id)
            caption = navigation.isPeeked(id) ? "Peeking \(name(id)) · ↩ opens it" : "Put \(name(id)) away"
        case let .cycle(direction):
            let id = navigation.neighbor(in: direction)
            animate { navigation.select(id) }
            learn(.cycle, "Moved to \(name(id))")
        case .togglePrimary:
            let id = navigation.toggleTarget
            animate { navigation.select(id) }
            learn(.main, id == navigation.primaryID ? "Back to Main" : "Back to \(name(id))")
        case .peekRecent:
            peekRecent()
        }
        return true
    }

    private func finish(_ outcome: TerminalHoldGesture.Outcome?) {
        guard let outcome else { return }
        holdTask?.cancel()
        holdTask = nil
        switch outcome {
        case let .select(number):
            guard let id = sessionID(number) else { return }
            animate { navigation.select(id) }
            learn(.select, "Switched to \(name(id))")
        case let .peek(number):
            guard let id = sessionID(number), id != navigation.primaryID, id != navigation.panelID,
                  !navigation.isPeeked(id) else { return }
            peek(id)
            holdPeekID = id
            learn(.holdPeek, "Peeking \(name(id)) · let go to hide, ↩ to open")
        case .endPeek:
            guard let id = holdPeekID else { return }
            holdPeekID = nil
            if navigation.isPeeked(id) {
                close(id)
                caption = "Let go, so \(name(id)) slid away"
            }
        }
    }

    private func peekRecent() {
        if let id = recentPeekID, navigation.isPeeked(id) {
            recentPeekID = nil
            close(id)
            learn(.peekLast, "⌘D again put \(name(id)) away")
            return
        }
        let shells = Set(sessions.dropFirst().map(\.id))
        guard let id = navigation.recentPeekCandidate(among: shells) else { return }
        peek(id)
        recentPeekID = id
        learn(.peekLast, "Peeking \(name(id)), the last terminal you used · ↩ opens it")
    }

    private func peek(_ id: UUID) {
        animate { navigation.peek(id, limit: peekLimit) }
        armedID = navigation.isPeeked(id) ? id : nil
    }

    private func close(_ id: UUID) {
        if armedID == id { armedID = nil }
        animate { navigation.closePeek(id) }
    }

    private func learn(_ lesson: Lesson, _ text: String) {
        learned.insert(lesson)
        caption = text
    }

    private func sessionID(_ number: Int) -> UUID? {
        sessions.indices.contains(number - 1) ? sessions[number - 1].id : nil
    }

    private func name(_ id: UUID) -> String { session(id)?.name ?? "Terminal" }

    private func animate(_ change: () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.16), change)
    }
}

struct OnboardingTerminalsStep: View {
    @ObservedObject var demo: OnboardingTerminalDemo

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Move between terminals").font(.title2.weight(.semibold))
                Text(demo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: demo.caption)
            }
            OnboardingWorkspaceSketch(demo: demo)
            Grid(horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(0 ..< 3, id: \.self) { row in
                    GridRow {
                        lesson(OnboardingTerminalDemo.Lesson.allCases[row * 2])
                        lesson(OnboardingTerminalDemo.Lesson.allCases[row * 2 + 1])
                    }
                }
            }
            .frame(maxWidth: 500)
        }
    }

    private func lesson(_ lesson: OnboardingTerminalDemo.Lesson) -> some View {
        let isDone = demo.learned.contains(lesson)
        return HStack(spacing: 6) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
            Text(lesson.title).font(.callout)
            Spacer(minLength: 4)
            OnboardingKeycaps(keys: lesson.keys, isDone: isDone)
        }
        .animation(.snappy(duration: 0.18), value: isDone)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "")
    }
}

/// Keycaps shared by the shortcut steps.
struct OnboardingKeycaps: View {
    let keys: [String]
    var isDone = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                if key == "hold" {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(key)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(isDone ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(isDone ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
                        }
                }
            }
        }
    }
}

/// A miniature of the workspace's terminal column: the tab strip, the panel, and peeks
/// sliding in from the right edge.
private struct OnboardingWorkspaceSketch: View {
    @ObservedObject var demo: OnboardingTerminalDemo

    var body: some View {
        let navigation = demo.navigation
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Array(demo.sessions.enumerated()), id: \.element.id) { index, session in
                    tab(session, number: index + 1,
                        isSelected: session.id == navigation.panelID,
                        isPeeked: navigation.isPeeked(session.id))
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            Divider()
            HStack(spacing: 8) {
                if let panel = demo.session(navigation.panelID) {
                    pane(panel)
                        .id(panel.id)
                        .transition(.opacity)
                }
                if !navigation.peekedIDs.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(navigation.peekedIDs, id: \.self) { id in
                            if let session = demo.session(id) {
                                pane(session, isPeek: true)
                                    .transition(.move(edge: .trailing))
                            }
                        }
                    }
                    .frame(width: 180)
                    .transition(.move(edge: .trailing))
                }
            }
            .padding(8)
            .frame(height: 118)
            .clipped()
        }
        .frame(maxWidth: 500)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Showing \(demo.session(navigation.panelID)?.name ?? "")"
            + (navigation.peekedIDs.isEmpty ? "" : ", peeking \(navigation.peekedIDs.compactMap { demo.session($0)?.name }.joined(separator: ", "))"))
    }

    private func tab(_ session: OnboardingTerminalDemo.Session, number: Int, isSelected: Bool, isPeeked: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(session.name == "Main" ? Color.secondary.opacity(0.45) : .green)
                .frame(width: 5, height: 5)
            Text(session.name).font(.caption).lineLimit(1)
            if demo.isCommandHeld {
                Text("\(number)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            if isPeeked {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .animation(.snappy(duration: 0.12), value: demo.isCommandHeld)
    }

    private func pane(_ session: OnboardingTerminalDemo.Session, isPeek: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(session.line)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(isPeek ? 1 : 2)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isPeek ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(isPeek ? 0.12 : 0), radius: 6, y: 2)
    }
}
