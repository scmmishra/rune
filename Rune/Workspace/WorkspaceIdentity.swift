import Foundation
import AppKit
import SwiftUI

struct WorkspaceFramePersistence: NSViewRepresentable {
    let path: String

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

struct WorkspaceIdentity: Codable, Hashable {
    let path: String

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
