import SwiftUI

@main
struct RuneApp: App {
    @State private var directoryURL = Self.initialDirectoryURL

    var body: some Scene {
        Window("Rune", id: "main") {
            WorkspaceView(directoryURL: directoryURL)
                .onOpenURL { url in
                    guard Self.isDirectory(url) else { return }
                    directoryURL = url.standardizedFileURL
                }
        }
        .defaultSize(width: 1_200, height: 760)
        .windowStyle(.hiddenTitleBar)
    }

    private static var initialDirectoryURL: URL? {
        guard let path = CommandLine.arguments.dropFirst().first else { return nil }

        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return isDirectory(url) ? url.standardizedFileURL : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
