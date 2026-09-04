import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(TypographyPreferenceKey.fontFamily)
    private var fontFamily = RuneTypography.defaultFamily
    @AppStorage(TypographyPreferenceKey.fontSize)
    private var fontSize = RuneTypography.defaultSize
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
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 220)
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
