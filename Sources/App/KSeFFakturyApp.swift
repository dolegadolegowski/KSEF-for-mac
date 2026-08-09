import SwiftUI

@main
struct KSeFFakturyApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("Faktury KSeF") {
            ContentView()
                .environmentObject(model)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1150, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Otwórz katalog dzienników") {
                    if let url = Log.shared.logFileURL {
                        model.revealInFinder(url)
                    }
                }
            }
        }

        // Scena ustawień jest automatycznie podpięta pod skrót ⌘,
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(settings)
        }
    }
}
