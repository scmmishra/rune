import AppKit
import SwiftUI
import GhosttyTerminal

struct TerminalPane: View {
    var focusRequest: Int = 0
    @State private var didRequestInitialFocus = false
    @ObservedObject var terminal: TerminalViewState
    var isVisible = true
    var onFocus: () -> Void = {}
    @Environment(\.runeTypography) private var typography

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .onChange(of: terminal.isFocused) {
                // Ghostty publishes focus on the next runloop turn. Check the
                // native responder too, so a stale notification cannot move a pane.
                if terminal.isFocused, let view = terminal.attachedPlatformView,
                   view.window?.firstResponder === view {
                    onFocus()
                }
            }
            .onChange(of: focusRequest) { if isVisible { terminal.requestFocus() } }
            .onChange(of: isVisible) {
                terminal.isSurfaceVisible = isVisible
                if isVisible {
                    terminal.requestFocus()
                } else if let view = terminal.attachedPlatformView,
                          view.window?.firstResponder === view {
                    view.window?.makeFirstResponder(nil)
                }
            }
            .accessibilityLabel("Terminal")
            .onAppear {
                applyTypography()
                terminal.isSurfaceVisible = isVisible
                // Request focus once, not on subsequent updates that could interrupt a palette.
                // Ghostty's imperative focus API avoids SwiftUI FocusState resets
                // resigning the native responder immediately after a session switch.
                // Source: libghostty-spm TerminalViewState.requestFocus (1.5.2).
                guard isVisible, !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                terminal.requestFocus()
            }
            .onChange(of: typography) {
                applyTypography()
            }
    }

    private func applyTypography() {
        let fontSize = Float(typography.size(relativeTo: 12))
        var surfaceConfiguration = terminal.configuration
        surfaceConfiguration.fontSize = fontSize
        terminal.configuration = surfaceConfiguration

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
    }
}

final class RuneTerminalView: TerminalView {
    private var isStopped = false
    private var isTrackingProcess = false
    private static var isAssociatingProcess = false
    private static var canAssociateProcesses = true
    private(set) var rootProcess: TerminalProcessMonitor.TerminationTarget?

    override func viewDidMoveToWindow() {
        trackProcessCreation { super.viewDidMoveToWindow() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        trackProcessCreation { super.setFrameSize(newSize) }
    }

    override func layout() {
        trackProcessCreation { super.layout() }
    }

    override func viewDidChangeBackingProperties() {
        trackProcessCreation { super.viewDidChangeBackingProperties() }
    }

    override var configuration: TerminalSurfaceOptions {
        get { super.configuration }
        set { trackProcessCreation { super.configuration = newValue } }
    }

    private func trackProcessCreation(_ update: () -> Void) {
        guard !isTrackingProcess, Self.canAssociateProcesses, rootProcess == nil, !isStopped,
              (delegate as? TerminalViewState)?.surface == nil else { update(); return }
        guard !Self.isAssociatingProcess else {
            // Reentrant creation of another terminal makes the child set ambiguous.
            Self.canAssociateProcesses = false
            update()
            return
        }
        isTrackingProcess = true
        Self.isAssociatingProcess = true
        defer {
            isTrackingProcess = false
            Self.isAssociatingProcess = false
        }
        let previous = TerminalProcessMonitor.childProcesses()
        update()
        guard Self.canAssociateProcesses, (delegate as? TerminalViewState)?.surface != nil else { return }
        rootProcess = TerminalProcessMonitor.newlyStartedProcess(after: previous)
        if rootProcess == nil {
            // A delayed child could otherwise be mistaken for the next terminal's
            // process, including in another window. Keep existing associations,
            // but stop making new ones after any ambiguous or timed-out launch.
            Self.canAssociateProcesses = false
        }
    }

    override var controller: TerminalController? {
        get { super.controller }
        set {
            guard !isStopped else { return }
            trackProcessCreation { super.controller = newValue }
        }
    }

    func stop() {
        // SwiftUI can retain removed views. Detach the controller to free the
        // PTY immediately, and prevent outgoing updates from recreating it.
        // Source: libghostty-spm TerminalSurfaceCoordinator.rebuildIfReady (1.5.2).
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
