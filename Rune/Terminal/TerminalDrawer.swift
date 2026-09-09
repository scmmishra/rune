import SwiftUI

struct TerminalDrawer: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isParked: Bool
    var isTabbed = false
    let onClose: () -> Void
    var onActivate: () -> Void = {}
    var onRunCommand: () -> Void = {}
    var onStopCommand: () -> Void = {}
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    private var showsHeader: Bool { !isTabbed || session.savedCommandID != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TerminalStatusDot(session: session)
                if isRenaming {
                    TextField("Terminal name", text: $draftName)
                        .textFieldStyle(.plain)
                        .runeFont(size: 12, weight: .medium)
                        .focused($isNameFocused)
                        .onSubmit { finishRenaming(returnFocus: true) }
                        .onExitCommand {
                            isRenaming = false
                            isNameFocused = false
                            if isVisible { session.terminal.requestFocus() }
                        }
                } else {
                    Text(session.name)
                        .runeFont(size: 12, weight: .medium)
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: beginRenaming)
                        // Activate immediately without waiting for the rename gesture to fail.
                        .simultaneousGesture(TapGesture().onEnded {
                            if !isRenaming { onActivate() }
                        })
                        .help(session.savedCommandID == nil ? "Double-click to rename terminal" : "Edit the saved command to change its name")
                        .accessibilityAction(named: "Focus terminal", onActivate)
                        .accessibilityAction(named: "Rename terminal", beginRenaming)
                }
                if session.savedCommandID != nil {
                    Text(session.commandStatus).runeFont(size: 11).foregroundStyle(.secondary)
                } else if session.hasExited {
                    Text("Exited").runeFont(size: 11).foregroundStyle(.secondary)
                }
                Spacer()
                if session.savedCommandID != nil {
                    if session.isCommandRunning {
                        Button(action: onStopCommand) { Image(systemName: "stop.fill") }
                            .help("Stop command")
                            .accessibilityLabel("Stop command")
                            .buttonStyle(WorkspaceButtonStyle())
                            .disabled(session.isStopping)
                    }
                    Button(action: onRunCommand) {
                        Image(systemName: session.isCommandRunning ? "arrow.clockwise" : "play.fill")
                    }
                    .help(session.isCommandRunning ? "Restart command" : "Run command")
                    .accessibilityLabel(session.isCommandRunning ? "Restart command" : "Run command")
                    .buttonStyle(WorkspaceButtonStyle())
                    .disabled(session.isStopping)
                }
                if !isTabbed {
                    Button(action: onClose) { Image(systemName: "chevron.right") }
                        .buttonStyle(WorkspaceButtonStyle())
                        .help("Hide Terminal (session keeps running)")
                        .accessibilityLabel("Hide terminal")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: showsHeader ? 38 : 0)
            .clipped()
            .opacity(showsHeader ? 1 : 0)
            .allowsHitTesting(showsHeader)
            .accessibilityHidden(!showsHeader)

            if showsHeader { Divider() }
            TerminalPane(
                terminal: session.terminal,
                isVisible: isVisible,
                isActive: !isParked,
                onActivate: onActivate,
                launchError: session.launchError
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: isTabbed ? 14 : 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isTabbed ? 14 : 12, style: .continuous)
                .stroke(Color.primary.opacity(isTabbed ? 0.10 : 0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isTabbed ? 0 : 0.22), radius: 24, y: 8)
        .onChange(of: isTabbed) { finishRenaming() }
        .onChange(of: isNameFocused) {
            if !isNameFocused { finishRenaming() }
        }
        .onChange(of: isVisible) {
            if !isVisible { finishRenaming() }
        }
    }

    private func beginRenaming() {
        guard session.savedCommandID == nil else { return }
        draftName = session.name
        isRenaming = true
        isNameFocused = true
    }

    private func finishRenaming(returnFocus: Bool = false) {
        guard isRenaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.customName = name }
        isRenaming = false
        isNameFocused = false
        if returnFocus && isVisible { session.terminal.requestFocus() }
    }
}
