import AppKit
import ApplicationServices
import Foundation

/// Opens the installed Kerio Control VPN Client and, when Accessibility allows,
/// clicks the official **Connect** or **Disconnect** control (menu extra or button).
///
/// This is **not** a Kerio protocol implementation. Public sources only document:
/// - TCP 4090 TLS control + UDP AES-GCM data (GFI KB / SEC Consult 2018)
/// - `libkvnet` LGPL virtual NIC, not the VPN handshake
/// - Linux `kerio-kvc start` reads `/etc/kerio-kvc.conf`; macOS `kvpncadm` has no public connect CLI
/// GitHub “clients” wrap the official `kvpncsvc` binary. There is no OSS protocol client to launch.
///
/// `scutil --nc start` on `com.kerio.VPN.fr.agent` is never used here (it fails with
/// “The VPN session failed because an internal error occurred”).
enum KerioLauncher {
    private static let agentBundleID = "com.kerio.VPN.fr.agent"
    private static let statusBundleID = "com.kerio.VPN.fr.status"

    private static let bundleIDs = [
        agentBundleID,
        statusBundleID,
        "com.kerio.VPN.fr.prefpanel"
    ]

    private static let agentPaths = [
        "/Applications/KVpnClientAgent.app"
    ]

    private static let statusPaths = [
        "/usr/local/kerio/vpnclient/KVpnClientStatus.app"
    ]

    private static let appPaths = [
        "/Applications/KVpnClientAgent.app",
        "/usr/local/kerio/vpnclient/KVpnClientStatus.app",
        "/Applications/Kerio Control VPN Client.app",
        "/Applications/Kerio VPN Client.app"
    ]

    private static let prefPanePaths = [
        "/Library/PreferencePanes/KVpnClient.prefPane",
        "/Library/PreferencePanes/Kerio Control VPN Client.prefPane",
        "/Library/PreferencePanes/Kerio VPN Client.prefPane"
    ]

    static var isInstalled: Bool {
        locateTarget() != nil || isServiceRunning
    }

    /// Kerio daemon running (VPN may still be disconnected).
    static var isServiceRunning: Bool {
        HelperService.runProcess("/usr/bin/pgrep", ["-x", "kvpncsvc"], timeoutSeconds: 2).ok
    }

    /// UI button — must not block the main thread. Launches the official apps and returns immediately.
    static func openClient() -> (ok: Bool, message: String) {
        let targets = launchTargets()
        guard !targets.isEmpty else {
            if isServiceRunning {
                return (true, "Kerio service is running — use the Kerio menu bar icon to Connect")
            }
            return (false, "Kerio VPN Client not found — install Kerio Control VPN Client first")
        }

        for url in targets {
            launch(url, activates: url.path.contains("KVpnClientAgent"), wait: 0)
        }

        let labels = targets.map(\.lastPathComponent).joined(separator: ", ")
        return (
            true,
            "Opened official Kerio client (\(labels)). Starts Kerio, then split — Kerio Split cannot log in for you."
        )
    }

    /// Background-only: open the official agent/menu extra, try to click Connect, then return.
    /// Does not speak Kerio TCP/UDP, does not dump credentials, does not call `scutil --nc start`.
    static func startOfficialSession(preferredServer: String) -> (ok: Bool, message: String) {
        let targets = launchTargets()
        guard !targets.isEmpty else {
            if isServiceRunning {
                return (
                    true,
                    "Kerio service is running. Kerio Split cannot log in; click Connect in Kerio."
                )
            }
            return (false, "Kerio VPN Client not found — install Kerio Control VPN Client first")
        }

        let alreadyUp = kerioUIRunning
        if !alreadyUp {
            for url in targets {
                launch(url, activates: false, wait: 0)
            }
            waitForKerioUI(timeout: 1.4)
        }

        if !AXIsProcessTrusted() {
            promptAccessibilityIfNeeded()
        }

        let click = clickOfficialMenu(preferredServer: preferredServer, wantDisconnect: false)
        let opened = targets.map(\.lastPathComponent).joined(separator: ", ")
        switch click.kind {
        case .clicked:
            return (true, "Started official Kerio client (\(opened)); clicked Connect (\(click.detail)). Waiting for tunnel, then split.")
        case .alreadyActive:
            return (true, "Official Kerio client is already connecting or connected (\(click.detail)). Waiting for tunnel, then split.")
        case .accessibilityOff:
            return (
                true,
                "Opened \(opened). This copy is not trusted for Accessibility yet. Toggle Kerio Split off/on in Privacy, then Relaunch (\(KerioLauncher.runningAppPath)). Or click Connect in Kerio."
            )
        case .noControl:
            return (
                true,
                "Opened \(opened). Kerio Split cannot log in; click Connect in Kerio (menu extra or Connect button)."
            )
        }
    }

    // MARK: - Launch

    private static func launchTargets() -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            urls.append(url)
        }

        add(urlForBundle(agentBundleID) ?? firstExisting(agentPaths))
        add(urlForBundle(statusBundleID) ?? firstExisting(statusPaths))
        if urls.isEmpty {
            add(locateTarget())
        }
        return urls
    }

    @discardableResult
    private static func launch(_ url: URL, activates: Bool, wait: TimeInterval) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        config.promptsUserIfNeeded = true

        if wait <= 0 {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            return true
        }

        var success = false
        let group = DispatchGroup()
        group.enter()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            success = (error == nil)
            group.leave()
        }
        _ = group.wait(timeout: .now() + wait)
        return success
    }

    private static var kerioUIRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: statusBundleID).isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).isEmpty
            || HelperService.runProcess("/usr/bin/pgrep", ["-x", "KVpnClientStatus"], timeoutSeconds: 1).ok
            || HelperService.runProcess("/usr/bin/pgrep", ["-x", "KVpnClientAgent"], timeoutSeconds: 1).ok
    }

    private static func waitForKerioUI(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kerioUIRunning { return }
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    private static func urlForBundle(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    private static func firstExisting(_ paths: [String]) -> URL? {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func locateTarget() -> URL? {
        for bid in bundleIDs {
            if let url = urlForBundle(bid) {
                return url
            }
        }
        for path in appPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for path in prefPanePaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let panes = try? FileManager.default.contentsOfDirectory(atPath: "/Library/PreferencePanes") {
            for name in panes where name.localizedCaseInsensitiveContains("kerio")
                || name.localizedCaseInsensitiveContains("kvpn") {
                return URL(fileURLWithPath: "/Library/PreferencePanes/\(name)")
            }
        }
        return nil
    }

    // MARK: - Accessibility / Automation

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var runningAppPath: String {
        Bundle.main.bundlePath
    }

    /// Main-thread: add this binary to Accessibility, open the pane, and ask to control System Events.
    /// The system “Open System Settings” button on the yellow padlock dialog is unreliable after a rebuild.
    @discardableResult
    static func ensureControlPermissions() -> Bool {
        let run = {
            if !AXIsProcessTrusted() {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                openAccessibilitySettings()
            }
            requestSystemEventsAutomation()
            return AXIsProcessTrusted()
        }
        if Thread.isMainThread {
            return run()
        }
        var trusted = false
        DispatchQueue.main.sync {
            trusted = run()
        }
        return trusted
    }

    static func openAccessibilitySettings() {
        openPrivacyURLs([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ])
    }

    static func openAutomationSettings() {
        openPrivacyURLs([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ])
    }

    static func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open -a \"\(path)\""]
        try? task.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private static func openPrivacyURLs(_ specs: [String]) {
        for spec in specs {
            if let url = URL(string: spec), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(settings)
        }
    }

    private static func requestSystemEventsAutomation() {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            typeWildCard,
            typeWildCard,
            true
        )
        if status == errAEEventNotPermitted {
            openAutomationSettings()
        }
    }

    private static func promptAccessibilityIfNeeded() {
        _ = ensureControlPermissions()
    }

    private struct ClickResult {
        enum Kind {
            case clicked
            case alreadyActive
            case noControl
            case accessibilityOff
        }
        var kind: Kind
        var detail: String
    }

    /// System Events — clicks Connect or Disconnect on the official Kerio menu extra / window.
    private static func clickOfficialMenu(preferredServer: String, wantDisconnect: Bool) -> ClickResult {
        let server = appleEscape(preferredServer.trimmingCharacters(in: .whitespacesAndNewlines))
        let wantOff = wantDisconnect ? "true" : "false"
        let source = """
        set preferredServer to "\(server)"
        set wantDisconnect to \(wantOff)
        tell application "System Events"
            -- Do not abort on "UI elements enabled"; that flag is stale after a rebuild.
            -- Per-app TCC is checked by the click itself.

            set procNames to {"KVpnClientStatus", "KVpnClientAgent"}
            set skipNames to {"Disconnecting...", "Connecting...", "Connected", "Disconnected", "Quit", "About", "Cancel", "OK", "Close", "Preferences", "Settings"}

            repeat with procNameRef in procNames
                set procName to procNameRef as text
                if exists process procName then
                    tell process procName
                        try
                            if (count of menu bar items of menu bar 1) > 0 then
                                set extraItem to menu bar item 1 of menu bar 1
                                click extraItem
                                delay 0.12
                                if exists menu 1 of extraItem then
                                    set clickedName to ""
                                    set alreadyName to ""
                                    set hostName to ""
                                    repeat with mi in menu items of menu 1 of extraItem
                                        set itemName to ""
                                        try
                                            set itemName to name of mi as text
                                        end try
                                        if itemName is not "" then
                                            if wantDisconnect then
                                                if itemName is "Connect" or itemName is "Disconnected" then
                                                    set alreadyName to itemName
                                                else if itemName is "Disconnect" and clickedName is "" then
                                                    set clickedName to itemName
                                                end if
                                            else
                                                if itemName is "Connecting..." or itemName is "Disconnect" or itemName is "Disconnecting..." then
                                                    set alreadyName to itemName
                                                else if itemName is "Connect" and clickedName is "" then
                                                    set clickedName to itemName
                                                else if preferredServer is not "" and itemName contains preferredServer and clickedName is "" then
                                                    if itemName is not in skipNames then set clickedName to itemName
                                                else if itemName contains "." and hostName is "" then
                                                    if itemName is not in skipNames and itemName does not start with "Kerio Control" then
                                                        set hostName to itemName
                                                    end if
                                                end if
                                            end if
                                        end if
                                    end repeat
                                    if alreadyName is not "" and clickedName is "" then
                                        try
                                            key code 53
                                        end try
                                        return "ALREADY:" & alreadyName
                                    end if
                                    if wantDisconnect is false then
                                        if clickedName is "" and hostName is not "" then set clickedName to hostName
                                    end if
                                    if clickedName is not "" then
                                        click menu item clickedName of menu 1 of extraItem
                                        return "CLICKED:menu:" & procName & ":" & clickedName
                                    end if
                                    try
                                        key code 53
                                    end try
                                end if
                            end if
                        end try

                        set winCount to 0
                        try
                            set winCount to count of windows
                        end try
                        set targetBtn to "Connect"
                        if wantDisconnect then set targetBtn to "Disconnect"
                        repeat with wIndex from 1 to winCount
                            try
                                tell window wIndex
                                    if exists button targetBtn then
                                        click button targetBtn
                                        return "CLICKED:button:" & procName
                                    end if
                                end tell
                            end try
                        end repeat
                    end tell
                end if
            end repeat
            return "NO_UI"
        end tell
        """

        let result = runAppleScript(source)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.ok {
            let lower = text.lowercased()
            if lower.contains("assistive") || lower.contains("not allowed") || text.contains("-25211") || text.contains("-1743") {
                DispatchQueue.main.async {
                    KerioLauncher.ensureControlPermissions()
                }
                return ClickResult(kind: .accessibilityOff, detail: text)
            }
            if lower.contains("ui elements") || lower.contains("accessibility") {
                DispatchQueue.main.async {
                    KerioLauncher.openAccessibilitySettings()
                }
                return ClickResult(kind: .accessibilityOff, detail: text)
            }
            return ClickResult(kind: .noControl, detail: text.isEmpty ? "AppleScript could not drive Kerio UI" : text)
        }

        if text.hasPrefix("CLICKED:") {
            return ClickResult(kind: .clicked, detail: String(text.dropFirst("CLICKED:".count)))
        }
        if text.hasPrefix("ALREADY:") {
            return ClickResult(kind: .alreadyActive, detail: String(text.dropFirst("ALREADY:".count)))
        }
        if text == "AX_OFF" {
            return ClickResult(kind: .accessibilityOff, detail: "Accessibility is off for Kerio Split")
        }
        return ClickResult(kind: .noControl, detail: text.isEmpty ? "No Connect control in Kerio UI" : text)
    }

    /// Click official Disconnect in the Kerio menu extra (same Accessibility path as Connect).
    static func stopOfficialSession() -> (ok: Bool, message: String) {
        let targets = launchTargets()
        if !kerioUIRunning {
            for url in targets {
                launch(url, activates: false, wait: 0)
            }
            waitForKerioUI(timeout: 1.0)
        }
        if !AXIsProcessTrusted() {
            promptAccessibilityIfNeeded()
        }
        let click = clickOfficialMenu(preferredServer: "", wantDisconnect: true)
        switch click.kind {
        case .clicked:
            return (true, "Clicked Disconnect in official Kerio client (\(click.detail)).")
        case .alreadyActive:
            return (true, "Kerio session already idle (\(click.detail)).")
        case .accessibilityOff:
            return (false, "Enable Accessibility for Kerio Split to click Disconnect, or Disconnect in the Kerio menu extra.")
        case .noControl:
            return (false, "Kerio Split cannot log out; click Disconnect in Kerio. \(click.detail)")
        }
    }

    private static func appleEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> (ok: Bool, text: String) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "\(error)"
            return (false, msg)
        }
        return (true, result?.stringValue ?? "")
    }
}
