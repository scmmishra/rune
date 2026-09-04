import SwiftUI
import GhosttyTerminal

struct TerminalPane: View {
    @StateObject private var terminal: TerminalViewState
    @Environment(\.runeTypography) private var typography

    init(workingDirectory: URL?) {
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
        _terminal = StateObject(wrappedValue: terminal)
    }

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .accessibilityLabel("Terminal")
            .onAppear(perform: applyTypography)
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
