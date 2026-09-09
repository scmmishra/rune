import AppKit
import SwiftUI

struct WorkspaceShortcutMonitor: NSViewRepresentable {
    let onQuickOpen: () -> Void
    let onCommands: () -> Void
    let onProjects: () -> Void
    let onBranches: () -> Void
    let onNewTerminal: () -> Void
    let onSelectTerminal: (Int) -> Void
    let onPeekTerminal: (Int) -> Void
    /// Returns true when a preview was actually dismissed, so Escape is only
    /// swallowed when it had something to do.
    let onDismissPeek: () -> Bool
    let onPromotePeek: () -> Void
    let onCycleTerminal: (Int) -> Void
    let onTogglePrimaryTerminal: () -> Void
    var preservesPreviewHunkShortcuts = false
    @Binding var isCommandHeld: Bool
    /// True while a freshly opened preview still owns Escape and Return.
    @Binding var isPeekArmed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        fileprivate func modifiersOnly(_ event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags.intersection([.command, .shift, .option, .control])
        }

        var parent: WorkspaceShortcutMonitor
        /// Set the moment this monitor opens a preview, so Escape and Return work
        /// without waiting for the view's state to travel back through SwiftUI.
        private var armedHere = false
        var monitor: Any?
        private var windowObservers: [NSObjectProtocol] = []

        init(parent: WorkspaceShortcutMonitor) { self.parent = parent }

        func install(for view: NSView) {
            // Clear hints when Command-Tab changes windows, even if Command is
            // released outside Rune. Only the key workspace may show its hints.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        guard let window = view?.window else { return }
                        self?.setCommandHeld(window.isKeyWindow && NSEvent.modifierFlags.contains(.command))
                    }
                })
            }
            // Native terminal/editor responders can consume menu equivalents before
            // SwiftUI sees them. Route Rune's workspace shortcuts in this window.
            // Source: https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self, weak view] event in
                guard let self, let window = view?.window,
                      window.isKeyWindow, event.window === window
                else { return event }

                let canHandle = window.attachedSheet == nil && NSApp.modalWindow == nil
                self.setCommandHeld(canHandle && event.modifierFlags.contains(.command))
                guard canHandle, event.type != .flagsChanged else { return event }

                if event.type == .keyDown, modifiersOnly(event).isEmpty {
                    // Escape dismisses an open shell preview however it was opened.
                    // The view reports whether there was one, so Escape reaches the
                    // shell untouched the rest of the time.
                    if event.keyCode == 53, self.parent.onDismissPeek() {
                        self.disarm()
                        return nil
                    }
                    // Return only promotes a preview that was just opened: otherwise
                    // it would fire every time you ran a command in the panel.
                    if event.keyCode == 36, self.armedHere || self.parent.isPeekArmed {
                        self.disarm()
                        self.parent.onPromotePeek()
                        return nil
                    }
                    if event.keyCode != 53, TerminalShortcut.matching(event) == nil { self.disarm() }
                }

                if let shortcut = TerminalShortcut.matching(event) {
                    // Preserve hunk navigation in previews, but never let a
                    // visible preview take terminal cycling from a focused shell.
                    if case .cycle = shortcut, self.parent.preservesPreviewHunkShortcuts,
                       !(window.firstResponder is RuneTerminalView) { return event }
                    if event.type == .keyDown, !event.isARepeat {
                        switch shortcut {
                        case let .select(number): self.parent.onSelectTerminal(number)
                        case let .peek(number):
                            self.parent.onPeekTerminal(number)
                            self.armedHere = true
                        case let .cycle(direction): self.parent.onCycleTerminal(direction)
                        case .togglePrimary: self.parent.onTogglePrimaryTerminal()
                        }
                    }
                    return nil
                }

                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let action: (() -> Void)?
                switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
                case ("p", .command): action = self.parent.onQuickOpen
                case ("p", [.command, .shift]): action = self.parent.onCommands
                case ("o", [.command, .shift]): action = self.parent.onProjects
                case ("b", [.command, .shift]): action = self.parent.onBranches
                case ("t", [.command, .shift]): action = self.parent.onNewTerminal
                default: action = nil
                }
                guard let action else { return event }
                if event.type == .keyDown, !event.isARepeat { action() }
                return nil
            }
        }

        private func disarm() {
            armedHere = false
            if parent.isPeekArmed { parent.isPeekArmed = false }
        }

        private func setCommandHeld(_ held: Bool) {
            if parent.isCommandHeld != held { parent.isCommandHeld = held }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
        }
    }
}
