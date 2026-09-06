import Combine
import Sparkle
import SwiftUI

final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    let controller: SPUStandardUpdaterController
    let isConfigured: Bool

    init() {
        // Local builds have no signing key and must never update over a development build.
        #if DEBUG
        isConfigured = false
        #else
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = Data(base64Encoded: key)?.count == 32
        #endif
        // Keep one controller for the app's lifetime, shared by all windows.
        // https://sparkle-project.org/documentation/programmatic-setup/#create-an-updater-in-swiftui
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured, updaterDelegate: nil, userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.controller.updater.checkForUpdates() }
            .disabled(!updater.isConfigured || !updater.canCheckForUpdates)
    }
}

struct UpdaterSettingsView: View {
    let updater: SPUUpdater
    @State private var automaticChecks: Bool
    @State private var automaticDownloads: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
    }

    var body: some View {
        // Sparkle owns these preferences. Write only when the user changes a control.
        // https://sparkle-project.org/documentation/preferences-ui/#adding-settings-in-swiftui
        Toggle("Automatically check for updates", isOn: $automaticChecks)
            .onChange(of: automaticChecks) { _, value in
                updater.automaticallyChecksForUpdates = value
            }
        Toggle("Automatically download and install updates", isOn: $automaticDownloads)
            .disabled(!automaticChecks)
            .onChange(of: automaticDownloads) { _, value in
                updater.automaticallyDownloadsUpdates = value
            }
    }
}
