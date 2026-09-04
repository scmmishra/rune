import SwiftUI

@main
struct RuneApp: App {
    var body: some Scene {
        WindowGroup("Rune", id: "workspace", for: WorkspaceIdentity.self) { $workspace in
            WorkspaceWindow(workspace: $workspace)
        }
        .defaultSize(width: 1_200, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            QuickOpenCommands()
        }
    }
}

private struct WorkspaceWindow: View {
    @Binding var workspace: WorkspaceIdentity?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var routedCommandLineDirectory = false
    @State private var recentWorkspaces = RecentWorkspaces.load()

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(directoryURL: workspace.directoryURL)
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
            .onAppear {
                guard !routedCommandLineDirectory, workspace == nil else { return }
                routedCommandLineDirectory = true

                if let directory = WorkspaceIdentity.commandLineDirectory {
                    open(directory)
                } else {
                    recentWorkspaces = RecentWorkspaces.load()
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
