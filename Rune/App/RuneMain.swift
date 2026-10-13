import SwiftUI

@main
enum RuneMain {
    /// What Claude Code sets for the processes it starts, to mark them as part of its session.
    private static let agentSessionMarkers = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_PLUGIN_DATA", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SESSION_ID",
    ]

    static func main() {
        // A Rune started by an agent, as `mise run dev` is from Claude Code, inherits that
        // agent's session markers and would hand them to every terminal. An agent started in
        // one of those terminals then takes itself for a child of the first: Claude Code
        // stops saving its transcript, and the session cannot be resumed.
        agentSessionMarkers.forEach { unsetenv($0) }
        if TerminalProcessGuardian.runIfRequested() { return }
        RuneApp.main()
    }
}
