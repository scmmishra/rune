import SwiftUI

struct TerminalStatusDot: View {
    @ObservedObject var session: TerminalSession

    private var status: String {
        if session.savedCommandID != nil { return session.commandStatus }
        if session.hasExited { return "Exited" }
        guard let process = session.processStatus else { return "Status unavailable" }
        if process.isIdle { return "Idle" }
        return process.isRunning ? "Running" : "Stopped"
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .help(status)
            .accessibilityLabel(status)
    }

    private var color: Color {
        if session.savedCommandID != nil {
            if session.isStopping { return .orange }
            if session.cleanupFailed { return .red }
            if session.isCommandRunning { return .green }
            if !session.wasStopped, let code = session.exitCode, code != 0 { return .red }
            return .secondary.opacity(0.45)
        }
        return session.processStatus?.isRunning == true && !session.hasExited ? .green : .secondary.opacity(0.45)
    }
}
