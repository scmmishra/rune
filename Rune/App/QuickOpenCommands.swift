import SwiftUI

extension FocusedValues {
    @Entry var presentQuickOpen: (() -> Void)?
}

struct QuickOpenCommands: Commands {
    @FocusedValue(\.presentQuickOpen) private var presentQuickOpen

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Quickly…") {
                presentQuickOpen?()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(presentQuickOpen == nil)
        }
    }
}
