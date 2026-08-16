import SwiftUI

@main
struct KerioSplitApp: App {
    @StateObject private var controller = TunnelController()

    var body: some Scene {
        WindowGroup("Kerio Split") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 420, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}
