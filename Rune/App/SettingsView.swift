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
    @AppStorage(TerminalLayout.preferenceKey) private var terminalLayout = TerminalLayout.slideovers
    @FocusState private var focusedField: Field?

    private enum Field {
        case family
        case size
    }

    var body: some View {
        Form {
            Section("Appearance") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Terminal layout")
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(TerminalLayout.allCases, id: \.self) { layout in
                            Button { terminalLayout = layout } label: {
                                TerminalLayoutCard(layout: layout, isSelected: terminalLayout == layout)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .accessibilityLabel(layout == .slideovers ? "Slideovers, recommended" : layout.title)
                            .accessibilityValue(terminalLayout == layout ? "Selected" : "Not selected")
                            .accessibilityAddTraits(terminalLayout == layout ? [.isSelected] : [])
                        }
                    }
                }
                Text("Switch layouts anytime. Your terminals keep running.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .frame(width: 480, height: 640)
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

private struct TerminalLayoutCard: View {
    let layout: TerminalLayout
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1))
                }
            HStack {
                Text(layout.title).fontWeight(.medium)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            Text(layout.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if layout == .slideovers {
                Text("Recommended")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in
                    Circle().fill(Color.secondary.opacity(0.35)).frame(width: 4, height: 4)
                }
                Spacer()
            }
            .padding(7)
            .background(Color.primary.opacity(0.04))
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<4) { index in
                        Capsule().fill(Color.secondary.opacity(0.2))
                            .frame(width: index == 0 ? 18 : 13, height: 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
                .background(Color.primary.opacity(0.03))
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if layout == .tabs {
                        HStack(spacing: 0) {
                            Text("Main").foregroundStyle(.secondary).padding(.horizontal, 6)
                            Text("Terminal 2").padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 7, weight: .medium))
                        Divider()
                    }
                    terminalLines
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .overlay(alignment: .trailing) {
                    if layout == .slideovers {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Terminal 2").font(.system(size: 7, weight: .medium))
                            Divider()
                            terminalLines
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .frame(width: 68)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.45))
                        }
                        .shadow(color: .black.opacity(0.12), radius: 3, x: -2, y: 1)
                        .padding(5)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityHidden(true)
    }

    private var terminalLines: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("❯").font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: 23, height: 3)
            }
            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 36, height: 3)
            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 27, height: 3)
        }
    }
}
