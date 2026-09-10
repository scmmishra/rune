import AppKit
import SwiftUI

enum OnboardingPreferenceKey {
    static let completed = "hasCompletedOnboarding"
}

/// First-launch welcome: shows what Rune does for agent work, teaches a few shortcuts by
/// pressing them, offers the `rune` command, and ends by opening a project. It never spotlights the real UI or asks for system permissions.
struct OnboardingView: View {
    /// Replays come from Help, where a workspace is already open, so a project is optional.
    let isReplay: Bool
    let onOpen: (WorkspaceIdentity) -> Void
    /// Finishes without a project: opens an empty Rune window, or just closes on a replay.
    let onClose: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, agents, shortcuts, commandLine, project
    }

    @State private var step = Step.welcome
    @State private var probe: OnboardingProbe?
    @State private var pressed: Set<String> = []
    @State private var recents = RecentWorkspaces.load()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: OnboardingWelcomeStep(probe: probe)
                case .agents: OnboardingAgentsStep()
                case .shortcuts: OnboardingShortcutsStep(pressed: pressed)
                case .commandLine: OnboardingCommandLineStep()
                case .project: OnboardingProjectStep(recents: recents, onOpen: onOpen, onSkip: isReplay ? nil : onClose)
                }
            }
            .id(step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 28)

            Divider()
            controls
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 600, height: 520)
        .background {
            OnboardingKeyMonitor { event in handle(event) }
        }
        .task {
            probe = await Task.detached(priority: .userInitiated) { OnboardingProbe.run() }.value
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            if step != .welcome {
                Button("Back") { go(-1) }
            }
            switch step {
            case .project:
                if isReplay {
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                }
            default:
                Button("Skip") { move(to: .project) }
                Button("Continue") { go(1) }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func go(_ offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        move(to: next)
    }

    private func move(to next: Step) {
        guard next != step else { return }
        if next == .project { recents = RecentWorkspaces.load() }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { step = next }
    }

    /// Returns true when the event was used, so shortcuts being practised never reach the menus.
    private func handle(_ event: NSEvent) -> Bool {
        guard step == .shortcuts, let shortcut = OnboardingShortcut.all.first(where: { $0.matches(event) }) else {
            if event.keyCode == 53, step != .project { move(to: .project); return true } // Escape skips
            return false
        }
        pressed.insert(shortcut.id)
        return true
    }
}

/// Routes keys for this window only. A local monitor sees ⌘P and friends before the menu
/// bar does, which is what lets the rune stones capture real app shortcuts.
private struct OnboardingKeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var handler: (NSEvent) -> Bool
        private var monitor: Any?

        init(handler: @escaping (NSEvent) -> Bool) { self.handler = handler }

        func install(for view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window, window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                return self.handler(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The welcome window's scene content: marks onboarding complete once a project loads.
struct OnboardingWindow: View {
    @AppStorage(OnboardingPreferenceKey.completed) private var hasCompleted = false
    @State private var isReplay = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        OnboardingView(isReplay: isReplay, onOpen: { workspace in
            hasCompleted = true
            RecentWorkspaces.record(workspace)
            openWindow(id: "workspace", value: workspace)
            dismiss()
        }, onClose: {
            // A replay returns to the workspace that is already open; a first run
            // opens an empty Rune window, which offers the project picker.
            // Mark completion first so the new window doesn't route back to onboarding.
            hasCompleted = true
            if !isReplay { openWindow(id: "workspace") }
            dismiss()
        })
        .onAppear { isReplay = hasCompleted }
    }
}
