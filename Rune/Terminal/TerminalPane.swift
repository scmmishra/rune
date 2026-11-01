import AppKit
import SwiftUI
import ObjectiveC

struct TerminalPane: View {
    @State private var didRequestInitialFocus = false
    @ObservedObject var terminal: TerminalViewState
    var isVisible = true
    var isActive = true
    var onActivate: () -> Void = {}
    var launchError: String?
    /// Fades the grid slightly while this terminal isn't taking keystrokes.
    var dimsWhenUnfocused = false
    @Environment(\.runeTypography) private var typography
    @Environment(\.runeTheme) private var runeTheme
    @Environment(\.controlActiveState) private var controlActiveState

    /// Only while the window is key: a terminal read from another app stays at full contrast.
    private var isDimmed: Bool {
        dimsWhenUnfocused && controlActiveState == .key && !terminal.isFocused
    }

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .overlay {
                runeTheme.surface
                    .opacity(isDimmed ? 0.3 : 0)
                    .allowsHitTesting(false)
                    // Focus hands off through a nil first responder; the delay keeps
                    // that instant from flashing the dim.
                    .animation(isDimmed ? .easeOut(duration: 0.12).delay(0.06) : .easeOut(duration: 0.08),
                               value: isDimmed)
                    .accessibilityHidden(true)
            }
            .overlay {
                if let launchError { Text(launchError).runeFont(size: 12).foregroundStyle(ThemeColor.red).padding(24) }
            }
            .onChange(of: isVisible) {
                terminal.isSurfaceVisible = isVisible
                if isVisible && isActive {
                    terminal.requestFocus()
                } else if !isVisible, let view = terminal.attachedPlatformView,
                          view.window?.firstResponder === view {
                    view.window?.makeFirstResponder(nil)
                }
            }
            .accessibilityLabel("Terminal")
            .onAppear {
                (terminal.attachedPlatformView as? RuneTerminalView)?.onActivate = onActivate
                applyTypography()
                // A terminal off screen missed any theme change made meanwhile.
                terminal.setTheme(runeTheme.terminalTheme)
                terminal.isSurfaceVisible = isVisible
                // Request focus once, not on subsequent updates that could interrupt a palette.
                // Ghostty's imperative focus API avoids SwiftUI FocusState resets
                // resigning the native responder immediately after a session switch.
                // Source: Rune/Terminal/Ghostty, TerminalViewState.requestFocus.
                guard isVisible, isActive, !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                terminal.requestFocus()
            }
            .onDisappear {
                (terminal.attachedPlatformView as? RuneTerminalView)?.onActivate = nil
            }
            .onChange(of: typography) {
                applyTypography()
            }
            .onChange(of: runeTheme) {
                terminal.setTheme(runeTheme.terminalTheme)
            }
    }

    private func applyTypography() {
        let fontSize = Float(typography.size(relativeTo: 12))
        if terminal.configuration.command == nil {
            var surfaceConfiguration = terminal.configuration
            surfaceConfiguration.fontSize = fontSize
            terminal.configuration = surfaceConfiguration
        }

        terminal.setTerminalConfiguration(
            TerminalConfiguration { builder in
                // Keep Ghostty's Command-0 reset target aligned with Rune's saved size.
                builder.withFontSize(fontSize)
                builder.withWindowPaddingX(12)
                builder.withWindowPaddingY(10)
                if let fontFamily = typography.resolvedFamily {
                    builder.withFontFamily(fontFamily)
                }
            }
        )
        if terminal.configuration.command != nil {
            // Changing surface options rebuilds the PTY and reruns its command.
            // Resize the existing font instead, including on the first appearance.
            // Source: https://ghostty.org/docs/config/keybind/reference#set_font_size
            terminal.surface?.performBindingAction("set_font_size:\(fontSize)")
        }
    }
}

final class RuneTerminalView: TerminalView {
    var onActivate: (() -> Void)?
    /// A ⌘-clicked link, reported before libghostty falls back to /usr/bin/open.
    var onOpenURL: ((String) -> Void)?
    private var isStopped = false
    private var linkDelegate: TerminalLinkDelegate?

    // libghostty only treats a link as handled when the surface delegate adopts its
    // open-URL protocol, and TerminalViewState does not. Wrap it so project files open
    // in Rune instead of whichever app macOS would launch.
    override var delegate: (any TerminalSurfaceViewDelegate)? {
        get { super.delegate }
        set {
            guard let state = newValue as? TerminalViewState else {
                linkDelegate = nil
                super.delegate = newValue
                return
            }
            let proxy = TerminalLinkDelegate(state: state)
            proxy.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
            linkDelegate = proxy
            super.delegate = proxy
        }
    }


    // Treat actual clicks as navigation intent. Ghostty's delayed published
    // focus changes can otherwise undo a keyboard switch during a handoff.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        onActivate?()
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        onActivate?()
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    override var controller: TerminalController? {
        get { super.controller }
        set {
            guard !isStopped else { return }
            super.controller = newValue
        }
    }

    func stop() {
        // SwiftUI can retain removed views. Detach the controller to free the
        // PTY immediately, and prevent outgoing updates from recreating it.
        // Source: Rune/Terminal/Ghostty, TerminalSurfaceCoordinator.rebuildIfReady.
        isStopped = true
        super.controller = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ghostty handles these as terminal bindings before AppKit reaches Rune's
        // Quit and Settings menu items. Leave app-level equivalents to macOS.
        if event.type == .keyDown,
           modifiers == .command,
           ["q", ","].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            return false
        }

        return super.performKeyEquivalent(with: event)
    }
}
