import SwiftUI

struct TerminalDrawer: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isParked: Bool
    var isTabbed = false
    /// A peek is a read-only preview: it never takes the keyboard, and a click
    /// promotes it into the panel rather than focusing it in place.
    var isPreview = false
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
                    // The session keeps running, so this reads as putting the preview
                    // away rather than as a terminate.
                    Button(action: onClose) { Image(systemName: "sidebar.right") }
                        .buttonStyle(WorkspaceButtonStyle())
                        .help("Dismiss this preview (the session keeps running)")
                        .accessibilityLabel("Dismiss preview")
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
                // A preview keeps rendering live output; it just never takes focus,
                // which is what isActive gates.
                isVisible: isVisible,
                isActive: !isParked && !isPreview,
                onActivate: isPreview ? {} : onActivate,
                launchError: session.launchError
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay {
                    if isPreview {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onActivate)
                            .help("Click or press Return to open this terminal in the panel")
                    }
                }
        }
        .background(TerminalSurface.color)
        // Tabbed sessions fill the terminal panel below the tab row, so they take the
        // panel's bottom corners and none of its border. A slideover is its own surface.
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: isTabbed ? 0 : 12,
                bottomLeadingRadius: isTabbed ? WorkspaceMetrics.panelRadius : 12,
                bottomTrailingRadius: isTabbed ? WorkspaceMetrics.panelRadius : 12,
                topTrailingRadius: isTabbed ? 0 : 12,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isTabbed ? 0 : 0.12), lineWidth: 1)
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
