import AppKit
import SwiftUI

@main
struct FotonKanbanApp: App {
    @State private var model = BoardModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.openLastFolder() }
        }
        // Breit genug, dass alle vier Spalten neben Seitenleiste und Inspector
        // Platz haben.
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Track") { model.createTrack() }
                    .keyboardShortcut("n")
                    .disabled(model.folderURL == nil)

                Divider()

                Button("Board-Ordner öffnen…") { chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Neu laden") { model.reload() }
                    .keyboardShortcut("r")
                    .disabled(model.folderURL == nil)
            }
        }
    }

    private func chooseFolder() {
        guard let url = FolderPicker.choose() else { return }
        model.open(url)
    }
}

/// Ordnerauswahl über den Standard-Dialog. Ausgelagert, weil sie sowohl aus dem
/// Menü als auch aus der Begrüßungsansicht aufgerufen wird.
enum FolderPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Öffnen"
        panel.message = "Ordner für das Board wählen — er wird bei Bedarf angelegt."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
