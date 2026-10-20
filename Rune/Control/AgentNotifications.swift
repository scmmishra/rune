import AppKit
import SwiftUI
import UserNotifications

/// What an agent asked to tell the user, shown in the window when it is focused.
struct AgentToast: Identifiable, Equatable {
    let id = UUID()
    let sessionID: UUID
    let title: String
    let message: String
}

/// macOS notifications from `rune_notify`, for a window that is not focused. Clicking one
/// brings its window forward with the agent's tab selected.
@MainActor
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifications()
    private nonisolated static let sessionKey = "session"

    /// Asks for permission the first time, not at launch: most people never get here.
    func post(title: String, message: String, sessionID: UUID) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        content.userInfo = [Self.sessionKey: sessionID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// Shows the banner while Rune is active too: another Rune window may be the focused one.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo[Self.sessionKey] as? String,
              let sessionID = UUID(uuidString: value) else { return }
        await MainActor.run { _ = RuneControlServer.shared.reveal(sessionID) }
    }
}

/// The toast at the top of the hub. Clicking it goes to the agent's tab.
struct AgentToastView: View {
    let toast: AgentToast
    let onSelect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .runeFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                Text(toast.message)
                    .runeFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(WorkspaceButtonStyle())
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
