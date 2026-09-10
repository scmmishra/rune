import AppKit
import SwiftUI

/// Setup facts shown on the welcome step.
nonisolated struct OnboardingProbe: Sendable {
    var git: String?

    static func run() -> OnboardingProbe {
        OnboardingProbe(git: gitVersion())
    }

    private static func gitVersion() -> String? {
        // /usr/bin/git is a shim that opens the Command Line Tools installer when they are
        // missing, so only run it once xcode-select confirms a developer directory exists.
        guard run("/usr/bin/xcode-select", ["-p"]) != nil,
              let output = run("/usr/bin/git", ["--version"]) else { return nil }
        return output.split(separator: " ").dropFirst(2).first.map(String.init)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let probe: OnboardingProbe?

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Welcome to Rune").font(.largeTitle.weight(.semibold))
                Text("A terminal-first workspace for building with coding agents.")
                    .foregroundStyle(.secondary)
            }
            // Nearly everyone has Git; say something only when it's missing.
            if let probe, probe.git == nil {
                Label("Rune's Git features need the Xcode Command Line Tools.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: probe?.git == nil)
    }
}

// MARK: - Agents

struct OnboardingAgentsStep: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Built for working with agents").font(.title2.weight(.semibold))
                Text("Run them side by side, then check what they changed.")
                    .foregroundStyle(.secondary)
            }
            OnboardingTabStrip()
            VStack(alignment: .leading, spacing: 14) {
                feature("circle.fill", color: .green, title: "See every agent at a glance",
                        detail: "Tabs take the name of the agent inside and show a green dot while it works.")
                feature("doc.text.magnifyingglass", color: .accentColor, title: "Understand what changed",
                        detail: "Change Brief explains a diff with diagrams and links back to the code.")
                feature("play.circle", color: .orange, title: "Keep your dev servers close",
                        detail: "Procfile commands run in their own terminals, and stop when Rune quits.")
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func feature(_ symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .imageScale(symbol == "circle.fill" ? .small : .medium)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A sketch of Rune's tab bar: a plain terminal starts an agent and the tab takes its name,
/// which shows the feature instead of describing it.
private struct OnboardingTabStrip: View {
    @State private var agentStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            tab(agentStarted ? "Claude Code" : "Terminal 2", running: agentStarted, selected: true)
            tab("Codex", running: false, selected: false)
            tab("web", running: true, selected: false, symbol: "play.fill")
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: 420)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)) }
        .accessibilityHidden(true)
        .task {
            if reduceMotion { agentStarted = true; return }
            // Loop gently so the change is noticed whenever the step is opened.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.snappy(duration: 0.25)) { agentStarted.toggle() }
                try? await Task.sleep(for: .seconds(agentStarted ? 2.6 : 0.6))
            }
        }
    }

    private func tab(_ name: String, running: Bool, selected: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 5, height: 5)
            if let symbol { Image(systemName: symbol).font(.system(size: 8)).foregroundStyle(.secondary) }
            Text(name)
                .font(.callout)
                .contentTransition(.opacity)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Shortcuts

/// A shortcut taught by pressing it.
struct OnboardingShortcut: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let keys: [String]
    let matches: (NSEvent) -> Bool

    init(id: String, title: String, symbol: String, keys: [String], key: String, modifiers: NSEvent.ModifierFlags) {
        self.init(id: id, title: title, symbol: symbol, keys: keys) { event in
            event.charactersIgnoringModifiers?.lowercased() == key &&
                event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers
        }
    }

    init(id: String, title: String, symbol: String, keys: [String], matches: @escaping (NSEvent) -> Bool) {
        (self.id, self.title, self.symbol, self.keys, self.matches) = (id, title, symbol, keys, matches)
    }

    static let all = [
        OnboardingShortcut(id: "find", title: "Find a file", symbol: "magnifyingglass",
                           keys: ["⌘", "P"], key: "p", modifiers: .command),
        OnboardingShortcut(id: "commands", title: "Command palette", symbol: "command",
                           keys: ["⇧", "⌘", "P"], key: "p", modifiers: [.command, .shift]),
        OnboardingShortcut(id: "terminal", title: "New terminal", symbol: "terminal",
                           keys: ["⇧", "⌘", "T"], key: "t", modifiers: [.command, .shift]),
        OnboardingShortcut(id: "project", title: "Switch project", symbol: "folder",
                           keys: ["⇧", "⌘", "O"], key: "o", modifiers: [.command, .shift]),
        OnboardingShortcut(id: "branch", title: "Switch branch", symbol: "arrow.triangle.branch",
                           keys: ["⇧", "⌘", "B"], key: "b", modifiers: [.command, .shift]),
    ]
}

struct OnboardingShortcutsStep: View {
    let pressed: Set<String>

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Keep your hands on the keyboard").font(.title2.weight(.semibold))
                Text("Try each shortcut now. Terminals are next.")
                    .foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(OnboardingShortcut.all.enumerated()), id: \.element.id) { index, shortcut in
                        if index > 0 { Divider() }
                        row(shortcut, isDone: pressed.contains(shortcut.id))
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: 420)
        }
    }

    private func row(_ shortcut: OnboardingShortcut, isDone: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: shortcut.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(shortcut.title)
            Spacer()
            HStack(spacing: 4) {
                ForEach(shortcut.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(isDone ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(isDone ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
                        }
                }
            }
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .opacity(isDone ? 1 : 0)
                .scaleEffect(isDone ? 1 : 0.6)
        }
        .padding(.vertical, 9)
        .animation(.snappy(duration: 0.18), value: isDone)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "")
    }
}

// MARK: - Open a project

struct OnboardingProjectStep: View {
    let recents: [WorkspaceIdentity]
    let onOpen: (WorkspaceIdentity) -> Void
    /// Nil on a replay, where Rune is already open.
    let onSkip: (() -> Void)?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(recents.isEmpty ? "Open a project" : "Pick up where you left off").font(.title2.weight(.semibold))
                Text("Switch any time with ⇧⌘O.").foregroundStyle(.secondary)
            }
            if recents.isEmpty { dropZone } else { recentList }
            HStack(spacing: 16) {
                if !recents.isEmpty {
                    Button("Open Directory…", action: choose)
                }
                if let onSkip {
                    Button("Open Rune", action: onSkip)
                        .buttonStyle(.link)
                        .help("Continue without opening a project")
                }
            }
        }
        // Folders can be dropped anywhere on the step, not only on the empty-state target.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if let workspace = WorkspaceIdentity(url: url) { onOpen(workspace) }
                }
            }
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop a folder here").foregroundStyle(.secondary)
            Button("Open Directory…", action: choose)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 420, minHeight: 170)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    private var recentList: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(recents.prefix(5).enumerated()), id: \.element.path) { index, workspace in
                    if index > 0 { Divider() }
                    OnboardingRecentRow(workspace: workspace) { onOpen(workspace) }
                }
            }
        }
        .frame(maxWidth: 420)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isTargeted ? 1 : 0)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let workspace = WorkspaceIdentity(url: url) else { return }
            onOpen(workspace)
        }
    }
}

private struct OnboardingRecentRow: View {
    let workspace: WorkspaceIdentity
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                Text(workspace.name).lineLimit(1)
                Text((workspace.path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(workspace.path)
    }
}
