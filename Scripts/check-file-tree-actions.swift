import AppKit

@main
struct FileTreeActionChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default

        let file = try FileTreeActions.createFile(named: "App.swift", in: root)
        precondition(manager.fileExists(atPath: file.path), "New file is created")
        precondition(file.lastPathComponent == "App.swift")

        do {
            _ = try FileTreeActions.createFile(named: "App.swift", in: root)
            preconditionFailure("A duplicate name must be refused")
        } catch let error as FileTreeActions.Failure {
            guard case .exists = error else { preconditionFailure("Wrong failure: \(error)") }
        }

        for name in ["", "   ", "a/b.swift", "a:b.swift"] {
            do {
                _ = try FileTreeActions.createFile(named: name, in: root)
                preconditionFailure("“\(name)” must be refused")
            } catch is FileTreeActions.Failure {}
        }

        let folder = try FileTreeActions.createFolder(named: "Sources", in: root)
        var isDirectory: ObjCBool = false
        precondition(manager.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                     "New folder is a directory")

        // Duplicates follow Finder's naming, and keep the extension.
        try Data("body".utf8).write(to: file)
        let copy = try FileTreeActions.duplicate(file)
        precondition(copy.lastPathComponent == "App copy.swift", "First copy: \(copy.lastPathComponent)")
        let copiedText = try String(contentsOf: copy, encoding: .utf8)
        precondition(copiedText == "body", "Contents are copied")
        let second = try FileTreeActions.duplicate(file)
        precondition(second.lastPathComponent == "App copy 2.swift", "Second copy: \(second.lastPathComponent)")
        let folderCopy = try FileTreeActions.duplicate(folder)
        precondition(folderCopy.lastPathComponent == "Sources copy", "Folders duplicate too")

        let renamed = try FileTreeActions.rename(file, to: "Main.swift")
        precondition(renamed.lastPathComponent == "Main.swift", "Rename moves the file")
        precondition(!manager.fileExists(atPath: file.path), "The old name is gone")
        let unchanged = try FileTreeActions.rename(renamed, to: "Main.swift")
        precondition(unchanged == renamed, "Renaming to the same name is a no-op")
        let cased = try FileTreeActions.rename(renamed, to: "MAIN.swift")
        precondition(cased.lastPathComponent == "MAIN.swift", "A case-only rename is allowed")
        do {
            _ = try FileTreeActions.rename(cased, to: "App copy.swift")
            preconditionFailure("Renaming onto an existing name must be refused")
        } catch is FileTreeActions.Failure {}

        try FileTreeActions.trash([cased])
        precondition(!manager.fileExists(atPath: cased.path), "Trashed items leave the project")

        print("File tree action checks passed")
    }
}
