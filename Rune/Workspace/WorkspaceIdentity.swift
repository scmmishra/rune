import Foundation
import AppKit
import SwiftUI

struct WorkspaceFramePersistence: NSViewRepresentable {
    /// The window's own name: its folder, and its setup when it has one.
    let path: String

    init(workspace: WorkspaceIdentity) {
        path = workspace.path + (workspace.setupID.map { "#" + $0 } ?? "")
    }

    func makeNSView(context: Context) -> FrameView { FrameView(path: path) }
    func updateNSView(_ view: FrameView, context: Context) {}

    final class FrameView: NSView {
        let path: String
        init(path: String) {
            self.path = path
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // AppKit saves frame changes and constrains restored frames to available screens.
            let name = "workspace:" + path
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
    }
}

/// What a workspace window shows: a repository's default space, or one of its setups.
/// The setup is part of the identity, so one repository can be open in both at once.
struct WorkspaceIdentity: Codable, Hashable {
    let path: String
    var setupID: String?

    init?(setup: WorkspaceSetup) {
        self.init(url: URL(fileURLWithPath: setup.repository, isDirectory: true))
        setupID = setup.id
    }

    init?(url: URL) {
        let directoryURL = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        path = directoryURL.path
    }

    var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var name: String {
        directoryURL.lastPathComponent
    }

    static var commandLineDirectory: WorkspaceIdentity? {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        return CommandLine.arguments
            .dropFirst()
            .lazy
            .map { URL(fileURLWithPath: $0, relativeTo: currentDirectory) }
            .compactMap(WorkspaceIdentity.init(url:))
            .first
    }
}

enum RecentWorkspaces {
    private static let defaultsKey = "recentWorkspacePaths"
    private static let maximumCount = 20

    static func load() -> [WorkspaceIdentity] {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return paths.compactMap { path in
            WorkspaceIdentity(url: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    static func record(_ workspace: WorkspaceIdentity) {
        let existingPaths = load().map(\.path)
        let paths = [workspace.path] + existingPaths.filter { $0 != workspace.path }
        UserDefaults.standard.set(Array(paths.prefix(maximumCount)), forKey: defaultsKey)
    }
}
