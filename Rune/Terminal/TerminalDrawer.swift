import SwiftUI

struct TerminalDrawer: View {
    enum Style {
        /// Beside the panel or parked off screen: a surface of its own, with a header.
        case floating
        /// The only pane of the panel while no tab is split: it fills the card below the tabs.
        case merged
        /// A pane among split panes: a card with a header and pane controls.
        case card
    }

    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isParked: Bool
    var style = Style.floating
    /// A peek is a read-only preview: it never takes the keyboard, and a click
    /// promotes it into the panel rather than focusing it in place.
    var isPreview = false
    /// Whether this pane is where the keyboard goes.
    var isFocused = false
    var isZoomed = false
    let onClose: () -> Void
    var onActivate: () -> Void = {}
    var onRunCommand: () -> Void = {}
    var onStopCommand: () -> Void = {}
    var onPane: (TerminalPaneAction) -> Void = { _ in }
    /// Ends the session once the user has confirmed.
    var onTerminate: () -> Void = {}
    /// Set for the main terminal, whose shell is replaced rather than removed.
    var onRestart: (() -> Void)?
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isHovered = false
    @State private var isConfirmingClose = false
    @FocusState private var isNameFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let controlsAnimation = Animation.snappy(duration: 0.16)

    /// Among split panes, only the focused one shows its header at full strength. The rest
    /// stay muted, hovered or not, so the eye goes to where typing lands.
    private var headerEmphasis: Double { style == .card && !isFocused ? 0.5 : 1 }

    private var headerHeight: CGFloat { style == .card ? 28 : 38 }

    private var showsHeader: Bool { style != .merged || session.savedCommandID != nil }
    private var showsPaneControls: Bool { style == .card && (isHovered || isFocused) }

    private var shape: UnevenRoundedRectangle {
        // A merged pane continues the panel's card from one point inside its border, so only
        // its bottom corners are round.
        let radius: CGFloat = switch style {
        case .floating: 12
        case .merged: WorkspaceMetrics.panelRadius - 1
        case .card: WorkspaceMetrics.panelRadius
        }
        let top: CGFloat = style == .merged ? 0 : radius
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius, topTrailingRadius: top, style: .continuous)
    }

    private var borderOpacity: Double {
        switch style {
        case .floating: 0.12
        case .merged: 0
        case .card: isFocused ? 0.18 : (colorScheme == .dark ? 0.08 : 0.06)
        }
    }

    private var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch style {
        case .floating: (0.22, 24, 8)
        case .merged: (0, 0, 0)
        case .card: (colorScheme == .dark ? 0.45 : 0.10, 10, 2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TerminalProcessIconView(session: session)
                    .foregroundStyle(.secondary)
                    .opacity(headerEmphasis)
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
                        // A pane's title is a label, not a heading: smaller and lighter than
                        // a preview's, and at full strength only where the keyboard is.
                        .runeFont(size: style == .card ? 11 : 12, weight: style == .card ? .regular : .medium)
                        .foregroundStyle(style == .card && !isFocused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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
                TerminalStatusDot(session: session)
                    .opacity(headerEmphasis)
                if session.savedCommandID != nil {
                    Text(session.commandStatus).runeFont(size: 11).foregroundStyle(.secondary)
                } else if session.hasExited {
                    Text("Exited").runeFont(size: 11).foregroundStyle(.secondary)
                }
                Spacer()
                TerminalResourceLabel(meter: session.resources)
                    .opacity(headerEmphasis)
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
                if style == .card {
                    paneControls
                } else if style == .floating {
                    // The session keeps running, so this reads as putting the preview
                    // away rather than as a terminate.
                    Button(action: onClose) { Image(systemName: "sidebar.right") }
                        .buttonStyle(WorkspaceButtonStyle())
                        .help("Dismiss this preview (the session keeps running)")
                        .accessibilityLabel("Dismiss preview")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: showsHeader ? headerHeight : 0)
            .clipped()
            .opacity(showsHeader ? 1 : 0)
            .allowsHitTesting(showsHeader)
            .accessibilityHidden(!showsHeader)

            // A pane's header shares the terminal's surface, so no rule sets it apart.
            if showsHeader, style != .card { Divider() }
            TerminalPane(
                terminal: session.terminal,
                // A preview keeps rendering live output; it just never takes focus,
                // which is what isActive gates.
                isVisible: isVisible,
                isActive: !isParked && !isPreview && isFocused,
                onActivate: isPreview ? {} : onActivate,
                launchError: session.launchError,
                dimsWhenUnfocused: style != .floating
            )
                // A respawned main shell needs a fresh platform view under the same ID.
                .id(ObjectIdentifier(session))
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
                .overlay {
                    if let onRestart, session.hasExited {
                        VStack(spacing: 12) {
                            Text(session.launchError ?? "The shell exited.")
                            Button("Restart Terminal", action: onRestart)
                        }
                        .runeFont(size: 12)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
        .clipShape(shape)
        // The shadow belongs to a static shape behind the content. Put on the
        // content, it would be recomputed from the terminal's pixels every frame.
        .background {
            shape.fill(TerminalSurface.color)
                .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
        }
        .overlay { shape.strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1) }
        // Animate the hover itself, not the header: an animation attached to the header
        // also catches the pane arriving from off screen on a tab switch, and slides its
        // title in.
        .onHover { hovering in withAnimation(Self.controlsAnimation) { isHovered = hovering } }
        .onChange(of: style) { finishRenaming() }
        .onChange(of: isNameFocused) {
            if !isNameFocused { finishRenaming() }
        }
        .onChange(of: isVisible) {
            if !isVisible { finishRenaming() }
        }
        .onChange(of: session.needsCloseConfirmation) {
            if session.needsCloseConfirmation {
                isConfirmingClose = true
                session.needsCloseConfirmation = false
            }
        }
        .alert("Close \(session.name)?", isPresented: $isConfirmingClose) {
            Button("Cancel", role: .cancel) {}
            Button("Close Terminal", role: .destructive, action: onTerminate)
        } message: {
            Text(onRestart != nil
                 ? "This ends the terminal’s running processes and starts a fresh terminal in its place."
                 : "This ends the terminal’s running processes.")
        }
    }

    /// Split, zoom and close. They stay out of the way until the pane is hovered or focused.
    private var paneControls: some View {
        HStack(spacing: 0) {
            UsageSeparator(meter: session.resources)
            Button { onPane(.split(.columns)) } label: { Image(systemName: "rectangle.split.2x1") }
                .help("Split Right (⌘D)")
                .accessibilityLabel("Split right")
            Button { onPane(.split(.rows)) } label: { Image(systemName: "rectangle.split.1x2") }
                .help("Split Down (⇧⌘D)")
                .accessibilityLabel("Split down")
            Button { onPane(.zoom) } label: {
                Image(systemName: isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(isZoomed ? "Restore Pane (⇧⌘↩)" : "Zoom Pane (⇧⌘↩)")
            .accessibilityLabel(isZoomed ? "Restore pane" : "Zoom pane")
            Button { onPane(.close) } label: { Image(systemName: "xmark") }
                .help("Close Pane (⌘W)")
                .accessibilityLabel("Close pane")
        }
        .buttonStyle(WorkspaceButtonStyle())
        .runeFont(size: 11)
        .foregroundStyle(.secondary)
        // Hidden controls take no room, so the usage readout rests against the header's
        // edge and slides left to make way for them.
        .fixedSize()
        .frame(width: showsPaneControls ? nil : 0, alignment: .leading)
        .clipped()
        .opacity(showsPaneControls ? headerEmphasis : 0)
        .allowsHitTesting(showsPaneControls)
        .accessibilityHidden(!showsPaneControls)
    }

    /// A rule between the usage readout and the pane controls, drawn only while there is a
    /// readout for it to separate.
    private struct UsageSeparator: View {
        @ObservedObject var meter: TerminalResourceMeter

        var body: some View {
            if meter.reading != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 12)
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)
            }
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
