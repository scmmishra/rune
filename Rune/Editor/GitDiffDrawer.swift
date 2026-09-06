import AppKit
import SwiftUI

struct GitDiffSelection: Equatable, Sendable {
    let change: GitChange
    let area: GitChange.Area
}

enum GitDiffNavigation {
    case previous
    case next
}

struct GitDiffDrawer: View {
    let rootURL: URL
    let change: GitChange
    let area: GitChange.Area
    var position: String?
    let onClose: () -> Void
    let onNavigate: (GitDiffNavigation) -> Void

    @State private var contents = ""
    @State private var loadError: String?
    @State private var isLoading = true

    private var fileURL: URL {
        rootURL.appending(path: change.path)
    }

    private var requestID: String {
        "\(area)-\(change.path)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Unable to Load Diff",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                CodeEditorView(
                    text: $contents,
                    fileURL: fileURL,
                    isEditable: false,
                    presentation: .diff
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .background {
            GitPreviewEscapeMonitor(onEscape: onClose, onNavigate: onNavigate)
        }
        .task(id: requestID) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            FileIconView(url: fileURL, isDirectory: false)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)

            Text(change.path)
                .runeFont(size: 12, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(area == .staged ? "Staged" : "Working Tree")
                .runeFont(size: 9, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())

            Spacer()

            if let position {
                Text(position).runeFont(size: 10).foregroundStyle(.secondary)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func load() async {
        isLoading = true
        loadError = nil

        let rootURL = rootURL
        let change = change
        let area = area
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.diff(for: change, area: area, at: rootURL)
        }.value

        guard !Task.isCancelled else { return }
        contents = result.contents
        loadError = result.errorMessage
        isLoading = false
    }
}

struct GitPreviewEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    var onNavigate: ((GitDiffNavigation) -> Void)?

    init(
        onEscape: @escaping () -> Void,
        onNavigate: ((GitDiffNavigation) -> Void)? = nil
    ) {
        self.onEscape = onEscape
        self.onNavigate = onNavigate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape, onNavigate: onNavigate)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onNavigate = onNavigate
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var onEscape: () -> Void
        var onNavigate: ((GitDiffNavigation) -> Void)?

        private weak var view: NSView?
        private var monitor: Any?
        private static let upArrowKeyCode: UInt16 = 126
        private static let downArrowKeyCode: UInt16 = 125

        init(
            onEscape: @escaping () -> Void,
            onNavigate: ((GitDiffNavigation) -> Void)?
        ) {
            self.onEscape = onEscape
            self.onNavigate = onNavigate
        }

        func install(for view: NSView) {
            self.view = view

            // Consume both halves of Escape so closing a diff cannot also exit
            // a full-screen workspace after the drawer leaves the view tree.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.window === self.view?.window else { return event }

                if event.charactersIgnoringModifiers == "\u{1B}" {
                    if event.type == .keyUp {
                        self.onEscape()
                    }
                    return nil
                }

                guard let onNavigate = self.onNavigate,
                      !self.isTextEditorFocused,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return event }

                let navigation: GitDiffNavigation? = switch event.keyCode {
                case Self.upArrowKeyCode: GitDiffNavigation.previous
                case Self.downArrowKeyCode: GitDiffNavigation.next
                default: nil
                }
                guard let navigation else { return event }

                if event.type == .keyDown {
                    onNavigate(navigation)
                }
                return nil
            }
        }

        private var isTextEditorFocused: Bool {
            view?.window?.firstResponder is NSTextView
        }

        func uninstall() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
