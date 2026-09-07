import AppKit
import SwiftUI
import GhosttyTerminal
import ObjectiveC

struct TerminalPane: View {
    var focusRequest: Int = 0
    @State private var didRequestInitialFocus = false
    @ObservedObject var terminal: TerminalViewState
    var isVisible = true
    var isActive = true
    var onActivate: () -> Void = {}
    @Environment(\.runeTypography) private var typography

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .onChange(of: focusRequest) { if isVisible && isActive { terminal.requestFocus() } }
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
                terminal.isSurfaceVisible = isVisible
                // Request focus once, not on subsequent updates that could interrupt a palette.
                // Ghostty's imperative focus API avoids SwiftUI FocusState resets
                // resigning the native responder immediately after a session switch.
                // Source: libghostty-spm TerminalViewState.requestFocus (1.5.2).
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
    var onActivate: (() -> Void)?
    private var isStopped = false
    private var isTrackingProcess = false
    private static var isAssociatingProcess = false
    private static var canAssociateProcesses = true
    private(set) var rootProcess: TerminalProcessMonitor.TerminationTarget?

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

    override var layer: CALayer? {
        get { super.layer }
        set {
            if let outgoing = super.layer, outgoing !== newValue {
                Self.retireDisplayCallback(on: outgoing)
            }
            super.layer = newValue
        }
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

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
        set {
            trackProcessCreation { super.configuration = newValue }
            if (delegate as? TerminalViewState)?.surface == nil, let layer {
                Self.retireDisplayCallback(on: layer)
            }
        }
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
            if newValue == nil, let layer { Self.retireDisplayCallback(on: layer) }
        }
    }

    func stop() {
        // SwiftUI can retain removed views. Detach the controller to free the
        // PTY immediately, and prevent outgoing updates from recreating it.
        // Source: libghostty-spm TerminalSurfaceCoordinator.rebuildIfReady (1.5.2).
        isStopped = true
        super.controller = nil
        if let layer { Self.retireDisplayCallback(on: layer) }
    }

    private static func retireDisplayCallback(on layer: CALayer) {
        // Ghostty 1.3.1 leaves raw renderer pointers on IOSurfaceLayer after
        // freeing the renderer. Core Animation can still display a retained
        // layer during a later transaction. Clear these only after teardown
        // has joined the renderer thread (including replacement during rebuild).
        // Source: src/renderer/metal/IOSurfaceLayer.zig in libghostty-spm 1.5.2.
        guard NSStringFromClass(type(of: layer)) == "IOSurfaceLayer" else { return }
        for name in ["display_cb", "display_ctx"] {
            guard let ivar = class_getInstanceVariable(type(of: layer), name) else { continue }
            // These ivars hold C pointers, despite their Objective-C encoding;
            // object_setIvar/KVC would apply object ownership to raw addresses.
            Unmanaged.passUnretained(layer).toOpaque().storeBytes(
                of: Optional<UnsafeRawPointer>.none,
                toByteOffset: ivar_getOffset(ivar),
                as: Optional<UnsafeRawPointer>.self
            )
        }
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
