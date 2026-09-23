import SwiftUI

struct TerminalStatusDot: View {
    @ObservedObject var session: TerminalSession
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String {
        if session.needsAttention { return "Waiting for you" }
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
            // A waiting terminal keeps breathing until you visit it: one nudge only helps
            // if you happened to be looking at the moment it arrived.
            .scaleEffect(isPulsing ? 1.5 : 1)
            .opacity(isPulsing ? 0.5 : 1)
            .animation(session.needsAttention && !reduceMotion
                       ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                       : .easeOut(duration: 0.12), value: isPulsing)
            .onChange(of: session.needsAttention, initial: true) {
                isPulsing = session.needsAttention && !reduceMotion
            }
            .help(status)
            .accessibilityLabel(status)
    }

    private var color: Color {
        // Attention outranks the process state: the point is that you have not seen it yet.
        if session.needsAttention { return .orange }
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
