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
    let onDismissPeek: () -> Void
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

                // A preview holds Escape and Return only until the next keystroke,
                // so a shell or editor in the panel keeps both keys.
                if event.type == .keyDown, self.parent.isPeekArmed {
                    let bare = modifiersOnly(event).isEmpty
                    if bare, event.keyCode == 53 {
                        self.parent.isPeekArmed = false
                        self.parent.onDismissPeek()
                        return nil
                    }
                    if bare, event.keyCode == 36 {
                        self.parent.isPeekArmed = false
                        self.parent.onPromotePeek()
                        return nil
                    }
                    if TerminalShortcut.matching(event) == nil { self.parent.isPeekArmed = false }
                }

                if let shortcut = TerminalShortcut.matching(event) {
                    // Preserve hunk navigation in previews, but never let a
                    // visible preview take terminal cycling from a focused shell.
                    if case .cycle = shortcut, self.parent.preservesPreviewHunkShortcuts,
                       !(window.firstResponder is RuneTerminalView) { return event }
                    if event.type == .keyDown, !event.isARepeat {
                        switch shortcut {
                        case let .select(number): self.parent.onSelectTerminal(number)
                        case let .peek(number): self.parent.onPeekTerminal(number)
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
