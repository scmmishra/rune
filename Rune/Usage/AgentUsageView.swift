import SwiftUI

/// Plan usage for the agent used last, Codex until one is. Click to see every agent.
struct AgentUsagePanel: View {
    @ObservedObject var sessions: TerminalSessions
    @StateObject private var model = AgentUsageModel()

    var body: some View {
        VStack(spacing: 0) {
            ActiveAgentObserver(session: sessions.active) { model.track($0) }
            AgentUsageCard(agent: model.lastAgent, model: model)
        }
        .frame(maxWidth: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// Observes only the selected session, so other terminals' process updates never
/// redraw the panel.
private struct ActiveAgentObserver: View {
    @ObservedObject var session: TerminalSession
    let onChange: (TerminalAgent?) -> Void

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onChange(of: session.agent, initial: true) { onChange(session.agent) }
    }
}

private struct AgentUsageCard: View {
    let agent: TerminalAgent
    @ObservedObject var model: AgentUsageModel
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .padding(.horizontal, WorkspaceMetrics.columnInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovered = $0 }
        .workspaceGroup()
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(model.isExpanded ? "Collapse usage" : "Show usage for every agent")
    }

    private var collapsed: some View {
        HStack(spacing: 8) {
            AgentMark(agent: agent)
            Text(agent.shortName)
                .foregroundStyle(.primary)
            summary(for: agent)
            Spacer(minLength: 4)
            chevron
        }
        .runeFont(size: 11)
        .lineLimit(1)
        .frame(height: 30)
    }

    @ViewBuilder
    private func summary(for agent: TerminalAgent) -> some View {
        // Only the limit closest to running out: it decides whether you can keep going.
        // On a tie the shorter window wins, since it resets first.
        let tightest = model.readings[agent]?.windows
            .filter { $0.shortTitle != nil }
            .reduce(nil) { (best: AgentUsage.Window?, window) in
                (best?.usedPercent ?? -1) < window.usedPercent ? window : best
            }
        if let window = tightest {
            HStack(spacing: 4) {
                Text(window.shortTitle ?? "").foregroundStyle(.secondary)
                Text(window.percentText).foregroundStyle(window.tint)
                if !window.resetText.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(window.resetText).foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
        } else {
            Text(model.errors[agent] == nil ? "Loading…" : "Unavailable")
                .foregroundStyle(.tertiary)
                .help(model.errors[agent] ?? "")
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AgentUsageModel.agents.enumerated()), id: \.element) { index, agent in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        AgentMark(agent: agent)
                        Text(agent.shortName).foregroundStyle(.primary)
                        if let plan = model.readings[agent]?.plan {
                            Text("· " + plan).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if index == 0 {
                            RefreshButton(isBusy: !model.loading.isEmpty, action: model.refresh)
                            chevron
                        }
                    }
                    .frame(height: 20)
                    if let usage = model.readings[agent] {
                        ForEach(usage.windows) { window in
                            UsageWindowRow(window: window)
                        }
                    }
                    if let error = model.errors[agent] {
                        Text(error)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.readings[agent] == nil {
                        Text("Loading…").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .runeFont(size: 11)
        .padding(.vertical, 8)
    }

    /// Quiet until pointed at: the card is a readout, not a toolbar.
    private struct RefreshButton: View {
        let isBusy: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .runeFont(size: 10, weight: .semibold)
                    .foregroundStyle(isHovered && !isBusy ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help("Refresh Usage")
            .accessibilityLabel("Refresh usage")
        }
    }

    private var chevron: some View {
        // The card is pinned to the bottom of the column, so it opens upward.
        Image(systemName: model.isExpanded ? "chevron.down" : "chevron.up")
            .runeFont(size: 9, weight: .semibold)
            .foregroundStyle(isHovered ? .secondary : .tertiary)
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.18)) { model.isExpanded.toggle() }
    }
}

private struct UsageWindowRow: View {
    let window: AgentUsage.Window

    var body: some View {
        HStack(spacing: 8) {
            Text(window.title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(window.percentText)
                .foregroundStyle(window.tint)
                .monospacedDigit()
            Text(window.resetText)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .leading)
        }
        .padding(.leading, 10)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The agent's own mark, vendored from Simple Icons and tinted like the row's text so
/// both read the same in either appearance. See Resources/SimpleIconsLicense.txt.
private struct AgentMark: View {
    let agent: TerminalAgent
    @Environment(\.runeTypography) private var typography

    var body: some View {
        if let asset = agent.markAsset {
            let side = typography.size(relativeTo: 11)
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private extension TerminalAgent {
    var shortName: String { self == .claude ? "Claude" : rawValue }

    var markAsset: String? {
        switch self {
        case .claude: "agent-claude"
        case .codex: "agent-codex"
        default: nil
        }
    }
}

private extension AgentUsage.Window {
    var percentText: String { "\(Int(usedPercent.rounded()))%" }

    var tint: Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .orange }
        return .secondary
    }

    /// "resets 2h 13m" within a day, otherwise the weekday: short enough for a sidebar.
    var resetText: String {
        guard let resetsAt else { return "" }
        let seconds = max(0, resetsAt.timeIntervalSinceNow)
        if seconds < 86_400 {
            let hours = Int(seconds) / 3600
            let minutes = Int(seconds) % 3600 / 60
            return "resets " + (hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
        }
        return "resets " + resetsAt.formatted(.dateTime.weekday(.abbreviated))
    }
}
