import AppKit
import SwiftUI

struct WorkspaceShortcutMonitor: NSViewRepresentable {
    let onQuickOpen: () -> Void
    let onCommands: () -> Void
    let onProjects: () -> Void
    let onBranches: () -> Void

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
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor
    final class Coordinator {
        var parent: WorkspaceShortcutMonitor
        var monitor: Any?

        init(parent: WorkspaceShortcutMonitor) { self.parent = parent }

        func install(for view: NSView) {
            // Native terminal/editor responders can consume menu equivalents before
            // SwiftUI sees them. Route only Rune's palette shortcuts in this window.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak view] event in
                guard let self, let window = view?.window,
                      window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil
                else { return event }

                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let action: (() -> Void)?
                switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
                case ("p", .command): action = self.parent.onQuickOpen
                case ("p", [.command, .shift]): action = self.parent.onCommands
                case ("o", [.command, .shift]): action = self.parent.onProjects
                case ("b", [.command, .shift]): action = self.parent.onBranches
                default: action = nil
                }
                guard let action else { return event }
                if event.type == .keyDown, !event.isARepeat { action() }
                return nil
            }
        }
    }
}
