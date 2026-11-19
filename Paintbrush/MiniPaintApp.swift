import SwiftUI

@main
struct MiniPaintApp: App {
    @StateObject private var model = CanvasModel()

    var body: some Scene {
        Window("MiniPaint", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 650)   // smallest the window can shrink to
        }
        .defaultSize(width: 1300, height: 850)          // size it opens at
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New…") { model.showingNewSheet = true }
                    .keyboardShortcut("n")
                Button("Open…") { model.openImage() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save…") { model.saveImage() }
                    .keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Canvas Image") { model.copyToClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}
