import AppKit
import SwiftUI
import GhosttyTerminal

struct TerminalPane: View {
    var focusRequest: Int = 0
    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @StateObject private var terminal: TerminalViewState
    @Environment(\.runeTypography) private var typography

    init(workingDirectory: URL?, focusRequest: Int = 0) {
        self.focusRequest = focusRequest
        let terminal = TerminalViewState(
            theme: TerminalTheme(
                light: TerminalConfiguration(startingFrom: .alabaster) { builder in
                    builder.withBackground("EFEFEF")
                },
                dark: TerminalConfiguration(startingFrom: .afterglow) { builder in
                    builder.withBackground("181818")
                }
            ),
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withWindowPaddingX(12)
                builder.withWindowPaddingY(10)
            }
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 12,
            workingDirectory: workingDirectory?.path
        )
        terminal.makePlatformView = {
            RuneTerminalView(frame: .zero)
        }
        _terminal = StateObject(wrappedValue: terminal)
    }

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .terminalFocused($isFocused)
            .onChange(of: focusRequest) { isFocused = true }
            .accessibilityLabel("Terminal")
            .onAppear {
                applyTypography()
                // Request focus once, not on subsequent updates that could interrupt a palette.
                guard !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                isFocused = true
            }
            .onChange(of: typography) {
                applyTypography()
            }
    }

    private func applyTypography() {
        let fontSize = Float(typography.size(relativeTo: 12))
        var surfaceConfiguration = terminal.configuration
        surfaceConfiguration.fontSize = fontSize
        terminal.configuration = surfaceConfiguration

        terminal.setTerminalConfiguration(
            TerminalConfiguration { builder in
                // Keep Ghostty's Command-0 reset target aligned with Rune's saved size.
                builder.withFontSize(fontSize)
                builder.withWindowPaddingX(12)
                builder.withWindowPaddingY(10)
                if let fontFamily = typography.resolvedFamily {
                    builder.withFontFamily(fontFamily)
                }
            }
        )
    }
}

private final class RuneTerminalView: TerminalView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ghostty handles these as terminal bindings before AppKit reaches Rune's
        // Quit and Settings menu items. Leave app-level equivalents to macOS.
        if event.type == .keyDown,
           modifiers == .command,
           ["q", ","].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            return false
        }

        return super.performKeyEquivalent(with: event)
    }
}
