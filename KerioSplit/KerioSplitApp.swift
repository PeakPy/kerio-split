import SwiftUI

@main
struct KerioSplitApp: App {
    @StateObject private var controller = TunnelController()

    var body: some Scene {
        WindowGroup("Kerio Split") {
            ContentView()
                .environmentObject(controller)
                .preferredColorScheme(scheme(for: controller.config.appearance))
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Kerio Split") {
                Button(controller.isActive ? "Disconnect Split" : "Connect Split") {
                    controller.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Reveal Config") { controller.revealConfigInFinder() }
                Button("Export Config…") { controller.exportConfig() }
                Button("Import Config…") { controller.importConfig() }
            }
        }
    }

    private func scheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
