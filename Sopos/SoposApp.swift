import SwiftUI

@main
struct SoposApp: App {
    @State private var player = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(player)
        }
    }
}
