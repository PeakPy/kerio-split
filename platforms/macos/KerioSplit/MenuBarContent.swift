import SwiftUI
import AppKit

/// Compact controls in the macOS menu bar (top-right status area).
struct MenuBarContent: View {
    @ObservedObject var controller: TunnelController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(controller.isActive ? "Split + VPN connected" : "Split tunneling OFF")
            Text(controller.menuBarSubtitle)

            Divider()

            Button("Connect All") {
                controller.connectAll()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(!controller.canConnectAll)

            if !controller.helperReady {
                Button("Install route helper") { controller.installHelper() }
                    .disabled(controller.isBusy)
            }

            Button("Disconnect All") {
                controller.requestDisconnect()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!controller.canDisconnectAll)

            if !controller.isActive, controller.kerioTunnelSeen {
                Button("Apply split only") {
                    controller.apply()
                }
                .disabled(controller.isBusy)
            }

            if !controller.kerioTunnelSeen {
                Button("Open Kerio VPN Client") {
                    controller.openKerioClient()
                }
                .disabled(controller.isBusy)
            }

            Button("Refresh status") {
                controller.refreshStatus()
                controller.probeNetwork()
            }
            .disabled(controller.isBusy)

            Divider()

            Button("Open Kerio Split…") {
                AppWindows.focusMain(openWindow: openWindow)
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("VPN Routes") {
                AppWindows.focusMain(openWindow: openWindow)
                NotificationCenter.default.post(name: .kerioSplitNavigate, object: AppSection.vpnRoutes)
            }

            Button("Settings") {
                AppWindows.focusMain(openWindow: openWindow)
                NotificationCenter.default.post(name: .kerioSplitNavigate, object: AppSection.settings)
            }

            Divider()

            Button("Quit Kerio Split") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .task {
            controller.onAppear()
            controller.startMonitoring()
        }
    }
}

enum AppWindows {
    static func focusMain(openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title.contains("Kerio Split") {
                window.makeKeyAndOrderFront(nil)
            }
            if let first = NSApp.windows.first(where: { $0.isVisible || $0.canBecomeMain }) {
                first.makeKeyAndOrderFront(nil)
            }
        }
    }

    static func showAbout(version: String) {
        let alert = NSAlert()
        alert.messageText = "Kerio Split"
        alert.informativeText = """
        Version \(version)

        Companion for Kerio Control VPN — applies split routes after a real tunnel is up. Not a Kerio protocol client.

        Open source · \(Brand.credit)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Notification.Name {
    static let kerioSplitNavigate = Notification.Name("kerioSplitNavigate")
}
