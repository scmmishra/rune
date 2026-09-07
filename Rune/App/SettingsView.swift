import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @AppStorage(TypographyPreferenceKey.fontFamily)
    private var fontFamily = RuneTypography.defaultFamily
    @AppStorage(TypographyPreferenceKey.fontSize)
    private var fontSize = RuneTypography.defaultSize
    @AppStorage(GuideAgent.preferenceKey)
    private var guideAgent = GuideAgent.defaultPreference
    @State private var fontSizeInput = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case family
        case size
    }

    var body: some View {
        Form {
            Section("Typography") {
                TextField("Font family", text: $fontFamily)
                    .focused($focusedField, equals: .family)

                TextField("Font size", text: $fontSizeInput)
                    .focused($focusedField, equals: .size)
                    .onSubmit(commitFontSize)

                Text("Font size must be between 8 and 24. Unavailable fonts use the system monospaced font.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Change Brief") {
                Picker("Preferred agent", selection: $guideAgent) {
                    ForEach(GuideAgent.allCases) { agent in
                        Text(agent.rawValue).tag(agent)
                    }
                }
                Text("Uses your installed agent and its existing login. This preference also updates the selection in the brief panel.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Updates") {
                if updater.isConfigured {
                    UpdaterSettingsView(updater: updater.controller.updater)
                    CheckForUpdatesButton(updater: updater)
                } else {
                    Text("Updates are available in release builds distributed through GitHub.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 500)
        .onAppear {
            fontSizeInput = String(Int(fontSize))
        }
        .onChange(of: fontSizeInput) {
            guard let value = Int(fontSizeInput), (8 ... 24).contains(value) else { return }
            fontSize = Double(value)
        }
        .onChange(of: focusedField) { previous, current in
            if previous == .size, current != .size {
                commitFontSize()
            }
        }
    }

    private func commitFontSize() {
        guard let value = Int(fontSizeInput), (8 ... 24).contains(value) else {
            fontSizeInput = String(Int(fontSize))
            return
        }
        fontSize = Double(value)
        fontSizeInput = String(value)
    }
}
