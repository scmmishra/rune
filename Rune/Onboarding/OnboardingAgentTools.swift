import SwiftUI

/// Offers to register Rune's MCP server with Claude Code and Codex, so an agent in a Rune
/// terminal can open files and panes in its window.
struct OnboardingAgentToolsStep: View {
    @StateObject private var connection = AgentConnectionModel()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Let agents use Rune").font(.title2.weight(.semibold))
                Text("An agent in a Rune terminal can work with the window it runs in.")
                    .foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    example("doc.text", "Open a file at the line it is talking about")
                    example("plusminus", "Show the diff of a change")
                    example("rectangle.split.2x1", "Start a dev server in a pane beside it")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 420)
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AgentConnection.Client.allCases) { client in
                        row(client)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                if connection.canConnect {
                    Button(connection.isConnecting ? "Connecting…" : "Connect Agents") {
                        Task { await connection.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(connection.isConnecting)
                    Text("Adds a server named rune to each agent's user settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(connection.errors, id: \.self) { error in
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
        }
        .task { await connection.refresh() }
    }

    private func example(_ symbol: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(detail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func row(_ client: AgentConnection.Client) -> some View {
        switch connection.statuses[client] {
        case nil:
            Label(client.name, systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .missing:
            Label("\(client.name) is not installed", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .notConnected:
            Label("\(client.name) is not connected", systemImage: "circle").foregroundStyle(.secondary)
        case .connectedElsewhere:
            Label("\(client.name) is connected to another copy of Rune", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .connected:
            Label("\(client.name) is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
