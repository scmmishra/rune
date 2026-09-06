import SwiftUI

extension FocusedValues {
    @Entry var presentQuickOpen: (() -> Void)?
    @Entry var presentCommandPalette: (() -> Void)?
    @Entry var saveCurrentFile: (() -> Void)?
    @Entry var presentRecentProjects: (() -> Void)?
}

struct QuickOpenCommands: Commands {
    @FocusedValue(\.presentQuickOpen) private var presentQuickOpen
    @FocusedValue(\.presentCommandPalette) private var presentCommandPalette
    @FocusedValue(\.saveCurrentFile) private var saveCurrentFile
    @FocusedValue(\.presentRecentProjects) private var presentRecentProjects

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Command Palette…") { presentCommandPalette?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(presentCommandPalette == nil)
            Button("Switch Project…") { presentRecentProjects?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(presentRecentProjects == nil)
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
