import AppKit
import SwiftUI

/// Installs the bundled `rune` script as a symlink, so updates to the app update the command.
enum CommandLineTool {
    static let installURL = URL(fileURLWithPath: "/usr/local/bin/rune")

    /// Common places a `rune` command may already live, including a development checkout's.
    private static let knownLocations: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [installURL.path, "/opt/homebrew/bin/rune", home + "/.local/bin/rune"]
    }()

    enum Status: Equatable {
        case installed
        case installedElsewhere(String)
        case notInstalled
        case unavailable(String)
    }

    static var bundledURL: URL? { Bundle.main.url(forResource: "rune", withExtension: nil) }

    static func status() -> Status {
        guard let bundled = bundledURL else { return .unavailable("This build of Rune doesn't include the command.") }
        // A translocated app runs from a random read-only path that disappears on quit.
        if bundled.path.contains("/AppTranslocation/") {
            return .unavailable("Move Rune to your Applications folder first, then reopen it.")
        }
        let manager = FileManager.default
        for path in knownLocations {
            guard let target = try? manager.destinationOfSymbolicLink(atPath: path) else {
                if manager.isExecutableFile(atPath: path) { return .installedElsewhere(path) }
                continue
            }
            let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: path).deletingLastPathComponent())
                .standardizedFileURL.path
            return resolved == bundled.standardizedFileURL.path ? .installed : .installedElsewhere(path)
        }
        return .notInstalled
    }

    /// The same install as a shell command, shown so people can see or run it themselves.
    static var manualCommand: String {
        "sudo ln -sf \(shellQuoted(bundledURL?.path ?? "/Applications/Rune.app/Contents/Resources/rune")) \(installURL.path)"
    }

    static func install() throws {
        guard let bundled = bundledURL else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? manager.destinationOfSymbolicLink(atPath: installURL.path)) != nil || manager.fileExists(atPath: installURL.path) {
                try manager.removeItem(at: installURL)
            }
            try manager.createSymbolicLink(at: installURL, withDestinationURL: bundled)
        } catch {
            // /usr/local/bin is usually root-owned. Ask for an administrator password only now,
            // after the person clicked Install. `do shell script` runs in-process, so it needs
            // no Automation permission.
            let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuoted(bundled.path)) \(installURL.path)"
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var errorInfo: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
                .executeAndReturnError(&errorInfo)
            if let errorInfo {
                // -128 is the user cancelling the password prompt: not an error worth showing.
                if errorInfo[NSAppleScript.errorNumber] as? Int == -128 { throw CancellationError() }
                throw NSError(domain: "Rune", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: errorInfo[NSAppleScript.errorMessage] as? String ?? "Installation failed.",
                ])
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct OnboardingCommandLineStep: View {
    @State private var status = CommandLineTool.status()
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Open projects from your shell").font(.title2.weight(.semibold))
                Text("The rune command opens any folder in Rune, right from the terminal.")
                    .foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    example("rune", "Open the current directory")
                    example("rune ~/code/api", "Open another folder")
                    example("git clone … && rune repo", "Jump straight into a fresh clone")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 420)
            action
                .frame(maxWidth: 420)
        }
    }

    private func example(_ command: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .frame(width: 200, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var action: some View {
        switch status {
        case .installed:
            Label("Installed at \(CommandLineTool.installURL.path)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .installedElsewhere(path):
            Label("A rune command is already installed at \((path as NSString).abbreviatingWithTildeInPath)",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case let .unavailable(reason):
            Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
        case .notInstalled:
            VStack(spacing: 10) {
                Button("Install Command", action: install)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Adds a link in /usr/local/bin. macOS may ask for your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("Or run it yourself:").foregroundStyle(.secondary)
                    Button(copied ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CommandLineTool.manualCommand, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.link)
                    .help(CommandLineTool.manualCommand)
                }
                .font(.callout)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func install() {
        error = nil
        do {
            try CommandLineTool.install()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        withAnimation(.snappy(duration: 0.18)) { status = CommandLineTool.status() }
    }
}
