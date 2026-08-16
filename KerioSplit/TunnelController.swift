import Foundation
import AppKit
import Combine
import Darwin
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class TunnelController: ObservableObject {
    @Published var isActive = false
    @Published var isBusy = false
    @Published var statusText = "Connect Kerio, then enable split tunneling"
    @Published var log = ""
    @Published var config = AppConfig.default
    @Published var jsonText = ""
    @Published var jsonError: String?
    @Published var helperReady = false
    @Published var newVpnRoute = ""
    @Published var newBypassRoute = ""
    @Published var newDns = ""
    @Published var inputError: String?
    @Published var showDisconnectConfirm = false
    @Published var kerioTunnelSeen = false
    @Published var tunnelInterfaces: [String] = []
    @Published var fullTunnelHijackSeen = false

    var configPathDisplay: String { configURL.path }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5.0"
    }

    var menuBarSubtitle: String {
        var parts: [String] = []
        parts.append(helperReady ? "Helper ready" : "Helper needed")
        if kerioTunnelSeen {
            let iface = tunnelInterfaces.first ?? "utun"
            parts.append(iface)
        } else {
            parts.append("No Kerio tunnel")
        }
        return parts.joined(separator: " · ")
    }

    var menuBarSymbol: String {
        if isActive { return "bolt.horizontal.circle.fill" }
        if kerioTunnelSeen { return "bolt.horizontal.circle" }
        return "circle.dashed"
    }

    private let fileManager = FileManager.default
    private var pollTimer: Timer?
    private var busyWatchdog: Timer?
    private var didBootstrap = false
    private var notificationsAuthorized = false
    private var statusPinnedUntil: Date?

    private var supportRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KerioSplit", isDirectory: true)
    }

    private var configURL: URL {
        supportRoot.appendingPathComponent("Config/config.json")
    }

    private var bundleRoot: URL {
        if let env = ProcessInfo.processInfo.environment["KERIOSPLIT_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("KerioSplitBundle", isDirectory: true),
           fileManager.fileExists(atPath: bundled.appendingPathComponent("Scripts/split-tunnel.sh").path) {
            return bundled
        }
        let downloads = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/KerioSplit", isDirectory: true)
        if fileManager.fileExists(atPath: downloads.appendingPathComponent("Scripts/split-tunnel.sh").path) {
            return downloads
        }
        return supportRoot
    }

    private var scriptsDir: URL { bundleRoot.appendingPathComponent("Scripts") }
    private var scriptURL: URL { scriptsDir.appendingPathComponent("split-tunnel.sh") }

    func onAppear() {
        guard !didBootstrap else {
            detectApplied()
            // Defer background work so first paint stays responsive.
            DispatchQueue.main.async { [weak self] in
                self?.probeNetwork()
                self?.refreshHelperStatus()
            }
            return
        }
        didBootstrap = true
        isBusy = false
        ensureWritableSupport()
        loadConfig()
        detectApplied()
        requestNotificationsIfNeeded()
        startMonitoring()

        // Everything that might talk to the system goes after the first frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncLaunchAtLoginFromSystem()
            self.refreshHelperStatus()
            self.probeNetwork()
            if self.config.options.autoApplyOnLaunch, self.helperReady, !self.isActive {
                self.apply()
            }
        }
    }

    func startMonitoring() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.detectApplied()
                self?.probeNetwork()
                self?.refreshHelperStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func syncLaunchAtLoginFromSystem() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enabled = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async {
                guard let self else { return }
                if self.config.options.launchAtLogin != enabled {
                    self.config.options.launchAtLogin = enabled
                    try? self.config.save(to: self.configURL)
                    self.syncJsonFromConfig()
                }
            }
        }
    }

    func refreshHelperStatus() {
        // Instant optimistic UI from filesystem only (no sudo on main).
        let installed = HelperService.isInstalled
        if !installed {
            helperReady = false
            if shouldUpdateStatusText() {
                statusText = "Install helper once to skip password prompts"
            }
            return
        }
        if !helperReady {
            helperReady = true // show ready immediately; verify below
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ready = HelperService.canRunPasswordless()
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperReady = ready
                guard self.shouldUpdateStatusText() else { return }
                if ready {
                    self.statusText = self.isActive
                        ? "Split ON — passwordless helper active"
                        : "Ready — passwordless helper active"
                } else {
                    self.statusText = "Helper present but sudoers not working — reinstall helper"
                }
            }
        }
    }

    private func pinStatus(_ text: String, seconds: TimeInterval = 8) {
        statusText = text
        statusPinnedUntil = Date().addingTimeInterval(seconds)
    }

    private func shouldUpdateStatusText() -> Bool {
        guard let until = statusPinnedUntil else { return true }
        return Date() >= until
    }

    private func setBusy(_ value: Bool) {
        isBusy = value
        busyWatchdog?.invalidate()
        busyWatchdog = nil
        guard value else { return }
        // Safety valve: never leave the Connect button spinning forever.
        busyWatchdog = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
                self.isBusy = false
                self.pinStatus("Timed out — see Activity", seconds: 12)
                self.appendLog("Busy state cleared after timeout")
            }
        }
        if let busyWatchdog {
            RunLoop.main.add(busyWatchdog, forMode: .common)
        }
    }

    func installHelper() {
        setBusy(true)
        syncScriptsToSupport()
        let supportScripts = supportRoot.appendingPathComponent("Scripts")
        let example = bundleRoot.appendingPathComponent("Config/config.example.json")
        let destExample = supportRoot.appendingPathComponent("Config/config.example.json")
        if fileManager.fileExists(atPath: example.path) {
            try? fileManager.createDirectory(
                at: supportRoot.appendingPathComponent("Config"),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destExample)
            try? fileManager.copyItem(at: example, to: destExample)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HelperService.install(fromBundleScripts: supportScripts)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                self.appendLog(result.text.isEmpty ? (result.ok ? "Helper installed" : "Install failed") : result.text)
                self.refreshHelperStatus()
                if result.ok {
                    self.pinStatus("Helper installed — Connect Split no longer needs a password")
                }
            }
        }
    }

    func uninstallHelper() {
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HelperService.uninstall()
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                self.appendLog(result.text)
                self.refreshHelperStatus()
            }
        }
    }

    func toggle() {
        if isActive {
            if config.options.confirmBeforeDisconnect {
                showDisconnectConfirm = true
            } else {
                restore()
            }
        } else {
            apply()
        }
    }

    /// Menu bar / quick actions skip the confirm dialog.
    func toggleFromMenuBar() {
        if isActive { restore() } else { apply() }
    }

    func confirmDisconnect() {
        showDisconnectConfirm = false
        restore()
    }

    func apply() {
        saveConfig(quiet: true)
        syncScriptsToSupport()
        runEngine(arguments: ["apply"]) { [weak self] ok, output in
            guard let self else { return }
            if ok || output.contains("split tunnel applied") || output.contains("hijack") {
                self.isActive = true
                self.pinStatus("Split ON — VPN routes + bypass applied")
                self.notify(title: "Split tunneling ON", body: "VPN routes applied. General traffic uses LAN.")
            }
            self.probeNetwork()
        }
    }

    func restore() {
        runEngine(arguments: ["restore"]) { [weak self] ok, _ in
            guard let self else { return }
            if ok {
                self.isActive = false
                self.clearAppliedMarkerLocally()
                self.pinStatus("Split OFF — Kerio session unchanged")
                self.notify(title: "Split tunneling OFF", body: "Routes restored. Kerio session left alone.")
            }
            self.probeNetwork()
        }
    }

    func refreshStatus() {
        runEngine(arguments: ["status"], preferUser: true) { [weak self] _, output in
            self?.appendLog(output)
            self?.pinStatus("Status refreshed", seconds: 4)
            self?.probeNetwork()
        }
    }

    func probeNetwork() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.scanNetwork()
            DispatchQueue.main.async {
                guard let self else { return }
                self.kerioTunnelSeen = result.hasKerio
                self.tunnelInterfaces = result.utuns
                self.fullTunnelHijackSeen = result.hasHijack
            }
        }
    }

    private nonisolated static func scanNetwork() -> (hasKerio: Bool, utuns: [String], hasHijack: Bool) {
        let routes = HelperService.runProcess("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeoutSeconds: 3).text
        let hijack = routes.contains("0/1") || routes.contains("128.0/1")

        let ifconfig = HelperService.runProcess("/sbin/ifconfig", [], timeoutSeconds: 3).text
        var candidates: [String] = []
        var current: String?
        for raw in ifconfig.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("utun"), let name = line.split(separator: ":").first {
                current = String(name)
                continue
            }
            guard let iface = current else { continue }
            if line.hasPrefix("\t") || line.hasPrefix(" ") {
                if line.contains("inet "),
                   line.contains("inet 10.") || line.contains("inet 172.") {
                    candidates.append(iface)
                    current = nil
                }
            } else if !line.isEmpty {
                current = nil
            }
        }
        let list = Array(Set(candidates)).sorted()
        let hasKerio = !list.isEmpty || hijack
        return (hasKerio, list, hijack)
    }

    private func requestNotificationsIfNeeded() {
        guard config.options.notifyOnChange else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.notificationsAuthorized = granted
            }
        }
    }

    private func notify(title: String, body: String) {
        guard config.options.notifyOnChange else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "keriosplit-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Config mutations

    func addVpnRoute() {
        guard let value = validatedHostOrCIDR(newVpnRoute, into: config.vpnRoutes) else { return }
        config.vpnRoutes.append(value)
        newVpnRoute = ""
        inputError = nil
        saveConfig()
    }

    func addBypassRoute() {
        guard let value = validatedHostOrCIDR(newBypassRoute, into: config.bypassRoutes) else { return }
        config.bypassRoutes.append(value)
        newBypassRoute = ""
        inputError = nil
        saveConfig()
    }

    func addDns() {
        guard let value = validatedHostOrCIDR(newDns, into: config.options.customDns, dnsOnly: true) else { return }
        config.options.customDns.append(value)
        newDns = ""
        inputError = nil
        saveConfig()
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard config.appearance != mode else { return }
        config.appearance = mode
        saveConfig(quiet: true)
    }

    func setShowMenuBar(_ enabled: Bool) {
        guard config.options.showMenuBar != enabled else { return }
        config.options.showMenuBar = enabled
        saveConfig(quiet: true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            config.options.launchAtLogin = enabled
            saveConfig()
            appendLog(enabled ? "Launch at login enabled" : "Launch at login disabled")
        } catch {
            appendLog("Launch at login: \(error.localizedDescription)")
            statusText = "Launch at login needs a signed app in Applications"
            // Keep UI honest if registration failed.
            config.options.launchAtLogin = SMAppService.mainApp.status == .enabled
            saveConfig()
        }
    }

    func clearLog() {
        log = ""
    }

    func copyConfigPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configURL.path, forType: .string)
        statusText = "Config path copied"
    }

    func exportConfig() {
        saveConfig()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "keriosplit-config.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try config.prettyJSON().write(to: url, atomically: true, encoding: .utf8)
            appendLog("Exported config → \(url.path)")
            statusText = "Config exported"
        } catch {
            appendLog("Export failed: \(error.localizedDescription)")
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = AppConfig.load(from: url)
            imported.sanitize()
            config = imported
            try config.save(to: configURL)
            syncJsonFromConfig()
            appendLog("Imported config ← \(url.path)")
            statusText = "Config imported"
        } catch {
            appendLog("Import failed: \(error.localizedDescription)")
        }
    }

    private func validatedHostOrCIDR(_ raw: String, into existing: [String], dnsOnly: Bool = false) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            inputError = "Enter an IP or CIDR"
            return nil
        }
        if dnsOnly {
            // DNS: host only, no CIDR
            guard AppConfig.isValidHostOrCIDR(value), !value.contains("/") else {
                inputError = "DNS must be an IPv4 address (no CIDR)"
                return nil
            }
        } else {
            guard AppConfig.isValidHostOrCIDR(value) else {
                inputError = "Use IPv4 or CIDR, e.g. 192.168.70.0/24"
                return nil
            }
        }
        guard !existing.contains(value) else {
            inputError = "Already in the list"
            return nil
        }
        return value
    }

    func removeVpnRoute(_ route: String) {
        config.vpnRoutes.removeAll { $0 == route }
        saveConfig()
    }

    func removeBypassRoute(_ route: String) {
        config.bypassRoutes.removeAll { $0 == route }
        saveConfig()
    }

    func removeDns(_ dns: String) {
        config.options.customDns.removeAll { $0 == dns }
        saveConfig()
    }

    func saveConfig(quiet: Bool = false) {
        ensureWritableSupport()
        config.sanitize()
        do {
            try config.save(to: configURL)
            let pretty = (try? config.prettyJSON()) ?? jsonText
            if jsonText != pretty {
                jsonText = pretty
            }
            jsonError = nil
            if !quiet {
                appendLog("Config saved → \(configURL.path)")
            }
        } catch {
            appendLog("Save failed: \(error.localizedDescription)")
        }
    }

    func reloadFromDisk() {
        ensureWritableSupport()
        loadConfig()
        appendLog("Reloaded from disk")
        statusText = "Config reloaded from JSON"
    }

    /// Apply JSON editor → model → disk (UI ↔ JSON both ways).
    func applyJsonEditor() {
        do {
            var parsed = try AppConfig.parse(json: jsonText)
            parsed.sanitize()
            config = parsed
            try config.save(to: configURL)
            syncJsonFromConfig()
            jsonError = nil
            appendLog("JSON applied and saved")
            statusText = "JSON config applied"
        } catch {
            jsonError = error.localizedDescription
            appendLog("JSON error: \(error.localizedDescription)")
        }
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    private func syncJsonFromConfig() {
        jsonText = (try? config.prettyJSON()) ?? jsonText
    }

    private func loadConfig() {
        if fileManager.fileExists(atPath: configURL.path) {
            config = AppConfig.load(from: configURL)
        } else {
            let example = bundleRoot.appendingPathComponent("Config/config.example.json")
            if fileManager.fileExists(atPath: example.path) {
                config = AppConfig.load(from: example)
            } else {
                config = .default
            }
            try? config.save(to: configURL)
        }
        syncJsonFromConfig()
    }

    private func detectApplied() {
        let state = supportRoot.appendingPathComponent("saved-routes.env")
        guard fileManager.fileExists(atPath: state.path),
              let data = try? String(contentsOf: state, encoding: .utf8) else {
            isActive = false
            return
        }
        isActive = data.contains("APPLIED_AT=")
    }

    private func clearAppliedMarkerLocally() {
        let state = supportRoot.appendingPathComponent("saved-routes.env")
        guard let data = try? String(contentsOf: state, encoding: .utf8) else { return }
        let filtered = data
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("APPLIED_AT=") }
            .joined(separator: "\n")
        // May fail if root-owned; restore script also clears this when helper works.
        try? filtered.write(to: state, atomically: true, encoding: .utf8)
        isActive = false
    }

    private func ensureWritableSupport() {
        let root = supportRoot
        let configDir = root.appendingPathComponent("Config", isDirectory: true)
        try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        // Never raise an admin password dialog during launch — that freezes the mouse cursor.
    }

    private func isWritable(_ url: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".write_test")
            try "ok".write(to: probe, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func syncScriptsToSupport() {
        let dest = supportRoot.appendingPathComponent("Scripts", isDirectory: true)
        try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let files = ["split-tunnel.sh", "keriosplit-ctl", "install-helper.sh"]
        for name in files {
            let src = scriptsDir.appendingPathComponent(name)
            let dst = dest.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try? fileManager.removeItem(at: dst)
            try? fileManager.copyItem(at: src, to: dst)
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
        // Also mirror config.example for installer
        let cfgSrc = bundleRoot.appendingPathComponent("Config/config.example.json")
        let cfgDstDir = supportRoot.appendingPathComponent("Config", isDirectory: true)
        try? fileManager.createDirectory(at: cfgDstDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: cfgSrc.path) {
            let exampleDst = cfgDstDir.appendingPathComponent("config.example.json")
            try? fileManager.removeItem(at: exampleDst)
            try? fileManager.copyItem(at: cfgSrc, to: exampleDst)
        }
    }

    private func runEngine(arguments: [String], preferUser: Bool = false, completion: ((Bool, String) -> Void)? = nil) {
        setBusy(true)
        let script = scriptURL.path
        let useHelper = !preferUser && (helperReady || HelperService.isInstalled)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: (ok: Bool, text: String)
            if useHelper {
                result = HelperService.runCtl(arguments)
            } else if preferUser || arguments.first == "status" {
                result = HelperService.runProcess("/bin/bash", [script] + arguments, timeoutSeconds: 20)
            } else {
                let quotedScript = script.replacingOccurrences(of: "'", with: "'\\''")
                let args = arguments.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
                result = appleScriptAdmin("/bin/bash '\(quotedScript)' \(args) 2>&1")
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                self.appendLog(result.text.isEmpty ? (result.ok ? "OK" : "Failed") : result.text)
                if !result.ok {
                    self.pinStatus("Action failed — see Activity", seconds: 10)
                }
                completion?(result.ok, result.text)
            }
        }
    }

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log = log.isEmpty ? trimmed : log + "\n———\n" + trimmed
    }
}
