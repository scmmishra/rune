import SwiftUI

@main
struct RuneApp: App {
    var body: some Scene {
        WindowGroup("Rune", id: "workspace", for: WorkspaceIdentity.self) { $workspace in
            WorkspaceWindow(workspace: $workspace)
                .runeTypographyPreferences()
        }
        .defaultSize(width: 1_200, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            QuickOpenCommands()
        }

        Settings {
            SettingsView()
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
    @State private var isProjectPickerPresented = false

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(directoryURL: workspace.directoryURL)
                    .id(workspace.path)
                    .background { WorkspaceFramePersistence(path: workspace.path) }
            } else if routedCommandLineDirectory {
                ProjectPickerView(
                    workspaces: recentWorkspaces,
                    onOpen: open
                )
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
            .navigationTitle(workspace?.name ?? "Rune")
            .focusedSceneValue(\.presentRecentProjects) {
                recentWorkspaces = RecentWorkspaces.load()
                isProjectPickerPresented = true
            }
            .sheet(isPresented: $isProjectPickerPresented) {
                ProjectPickerView(workspaces: recentWorkspaces) { directory in
                    isProjectPickerPresented = false
                    open(directory)
                }
                .frame(width: 560, height: 440)
                .onExitCommand { isProjectPickerPresented = false }
            }
            .onAppear {
                if let workspace { RecentWorkspaces.record(workspace) }
                guard !routedCommandLineDirectory, workspace == nil else { return }
                routedCommandLineDirectory = true

                if let directory = WorkspaceIdentity.commandLineDirectory {
                    open(directory)
                } else {
                    recentWorkspaces = RecentWorkspaces.load()
                    if let recent = recentWorkspaces.first { open(recent) }
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
}
