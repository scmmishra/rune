import SwiftUI

@main
enum RuneMain {
    static func main() {
        if TerminalProcessGuardian.runIfRequested() { return }
        RuneApp.main()
    }
}
