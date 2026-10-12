import SwiftUI

@main
struct SoposApp: App {
    @State private var player = PlayerModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Sopos", id: "main") {
            MacContentView().environment(player)
        }
        .defaultSize(width: 920, height: 640)
        .commands { PlaybackCommands(player: player) }

        Settings {
            SettingsView().environment(player)
        }
        #else
        WindowGroup {
            ContentView().environment(player)
        }
        #endif
    }
}
