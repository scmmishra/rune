import SwiftUI

extension FocusedValues {
    @Entry var presentQuickOpen: (() -> Void)?
    @Entry var saveCurrentFile: (() -> Void)?
}

struct QuickOpenCommands: Commands {
    @FocusedValue(\.presentQuickOpen) private var presentQuickOpen
    @FocusedValue(\.saveCurrentFile) private var saveCurrentFile

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Quickly…") {
                presentQuickOpen?()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(presentQuickOpen == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                saveCurrentFile?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveCurrentFile == nil)
        }
    }
}
