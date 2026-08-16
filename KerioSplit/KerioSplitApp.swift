import SwiftUI
import AppKit

@main
struct KerioSplitApp: App {
    @StateObject private var controller = TunnelController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Local state only — NEVER bind MenuBarExtra.isInserted directly to config+saveConfig
    /// (that causes an infinite SwiftUI update loop / spinning mouse cursor).
    @State private var menuBarVisible = true

    var body: some Scene {
        WindowGroup("Kerio Split", id: "main") {
            ContentView()
                .environmentObject(controller)
                .preferredColorScheme(scheme(for: controller.config.appearance))
                .onAppear {
                    menuBarVisible = controller.config.options.showMenuBar
                }
                .onReceive(controller.$config) { cfg in
                    if menuBarVisible != cfg.options.showMenuBar {
                        menuBarVisible = cfg.options.showMenuBar
                    }
                }
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

        MenuBarExtra(isInserted: $menuBarVisible) {
            MenuBarContent(controller: controller)
        } label: {
            // Keep label static-ish to avoid extra scene invalidations.
            Image(systemName: controller.isActive ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
        }
        .menuBarExtraStyle(.menu)
    }

    private func scheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
