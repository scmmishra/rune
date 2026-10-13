import SwiftUI

struct RuneApp: App {
    @StateObject private var updater = AppUpdater.shared

    init() {
        // Keep project windows separate even when macOS prefers opening windows as tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup("Rune", id: "workspace", for: WorkspaceIdentity.self) { $workspace in
            WorkspaceWindow(workspace: $workspace)
                .runeTypographyPreferences()
        }
        .defaultSize(width: 1_200, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            QuickOpenCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
        }

        Window("Welcome to Rune", id: "onboarding") {
            OnboardingWindow()
                .runeTypographyPreferences()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(updater: updater)
                .runeTypographyPreferences()
        }
    }
}

private struct WorkspaceWindow: View {
    @Binding var workspace: WorkspaceIdentity?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var routedCommandLineDirectory = false
    @State private var recentWorkspaces = RecentWorkspaces.load()
    @AppStorage(OnboardingPreferenceKey.completed) private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if let workspace {
                // The workspace names its own window, since a setup can be renamed while open.
                WorkspaceView(directoryURL: workspace.directoryURL, setupID: workspace.setupID,
                              onOpenProject: chooseProject, onOpenWorkspace: open)
                    .id(workspace)
                    .background { WorkspaceFramePersistence(workspace: workspace) }
            } else if routedCommandLineDirectory {
                ProjectPickerView(
                    workspaces: recentWorkspaces, setups: WorkspaceSetupStore.all(),
                    onClose: {}, onOpen: open, onChooseDirectory: chooseProject
                )
                .frame(width: 600, height: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Rune")
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .navigationTitle("Rune")
            }
        }
            .onAppear {
                if let workspace { RecentWorkspaces.record(workspace) }
                guard !routedCommandLineDirectory, workspace == nil else { return }
                routedCommandLineDirectory = true

                if let directory = WorkspaceIdentity.commandLineDirectory {
                    open(directory)
                } else {
                    recentWorkspaces = RecentWorkspaces.load()
                    if !hasCompletedOnboarding {
                        // Everyone sees the welcome once, existing users included; its last
                        // step lists their recent projects so nobody loses their place.
                        openWindow(id: "onboarding")
                        DispatchQueue.main.async { dismiss() }
                    } else if let recent = recentWorkspaces.first {
                        open(recent)
                    }
                }
            }
            .onOpenURL { url in
                guard let directory = WorkspaceIdentity(url: url) else { return }
                open(directory)
            }
    }

    private func open(_ directory: WorkspaceIdentity) {
        RecentWorkspaces.record(directory)
        recentWorkspaces = RecentWorkspaces.load()
        openWindow(id: "workspace", value: directory)

        if workspace == nil {
            DispatchQueue.main.async {
                dismiss()
            }
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let directory = WorkspaceIdentity(url: url) else { return }
            open(directory)
        }
    }
}
