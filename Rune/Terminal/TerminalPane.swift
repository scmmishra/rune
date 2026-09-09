import AppKit
import SwiftUI
import GhosttyTerminal
import ObjectiveC

struct PrimaryTerminalPane: View {
    @ObservedObject var session: TerminalSession
    let focusRequest: Int
    let isActive: Bool
    let onActivate: () -> Void
    let onRestart: () -> Void

    var body: some View {
        TerminalPane(focusRequest: focusRequest, terminal: session.terminal,
                     isActive: isActive, onActivate: onActivate)
            // A respawn needs a fresh platform view even though the navigation ID is unchanged.
            .id(ObjectIdentifier(session))
            .overlay {
                if session.hasExited {
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
}

struct TerminalPane: View {
    var focusRequest: Int = 0
    @State private var didRequestInitialFocus = false
    @ObservedObject var terminal: TerminalViewState
    var isVisible = true
    var isActive = true
    var onActivate: () -> Void = {}
    var launchError: String?
    @Environment(\.runeTypography) private var typography

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .overlay {
                if let launchError { Text(launchError).runeFont(size: 12).foregroundStyle(.red).padding(24) }
            }
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
    private var isStopped = false


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

    override var configuration: TerminalSurfaceOptions {
        get { super.configuration }
        set {
            super.configuration = newValue
            if (delegate as? TerminalViewState)?.surface == nil, let layer {
                Self.retireDisplayCallback(on: layer)
            }
        }
    }

    override var controller: TerminalController? {
        get { super.controller }
        set {
            guard !isStopped else { return }
            super.controller = newValue
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
