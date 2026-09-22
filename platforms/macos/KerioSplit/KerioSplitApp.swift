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
            CommandGroup(replacing: .appInfo) {
                Button("About Kerio Split") {
                    AppWindows.showAbout(version: controller.appVersion)
                }
            }
            CommandMenu("Kerio Split") {
                Button("Connect All") {
                    controller.connectAll()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!controller.canConnectAll)
                Button("Disconnect All") {
                    controller.requestDisconnect()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!controller.canDisconnectAll)
                Divider()
                Button("Copy Flight Log") {
                    controller.copyFlightLog()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Reveal Flight Log") {
                    controller.revealFlightLog()
                }
                Divider()
                Button("Reveal Config") { controller.revealConfigInFinder() }
                Button("Export Config…") { controller.exportConfig() }
                Button("Import Config…") { controller.importConfig() }
            }
        }

        MenuBarExtra(isInserted: $menuBarVisible) {
            MenuBarContent(controller: controller)
        } label: {
            // Same logo mark as everywhere else (transparent template, no dark plate).
            Image(nsImage: Brand.menuBarImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
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
