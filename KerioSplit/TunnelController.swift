import Foundation
import AppKit
import Combine
import Darwin
import ServiceManagement
import UniformTypeIdentifiers

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

    var configPathDisplay: String { configURL.path }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.0"
    }

    private let fileManager = FileManager.default

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
        ensureWritableSupport()
        loadConfig()
        syncLaunchAtLoginFromSystem()
        refreshHelperStatus()
        detectApplied()
        if config.options.autoApplyOnLaunch, helperReady, !isActive {
            apply()
        }
    }

    private func syncLaunchAtLoginFromSystem() {
        let enabled = SMAppService.mainApp.status == .enabled
        if config.options.launchAtLogin != enabled {
            config.options.launchAtLogin = enabled
            try? config.save(to: configURL)
            syncJsonFromConfig()
        }
    }

    func refreshHelperStatus() {
        helperReady = HelperService.canRunPasswordless()
        if helperReady {
            statusText = isActive
                ? "Split ON — passwordless helper active"
                : "Ready — passwordless helper active"
        } else if HelperService.isInstalled {
            statusText = "Helper present but sudoers not working — reinstall helper"
        } else {
            statusText = "Install helper once to skip password prompts"
        }
    }

    func installHelper() {
        isBusy = true
        syncScriptsToSupport()
        // Install from Application Support copy so paths resolve cleanly.
        let supportScripts = supportRoot.appendingPathComponent("Scripts")
        // Ensure install-helper sees Config/ next to Scripts/
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
        Task.detached { [weak self] in
            let result = HelperService.install(fromBundleScripts: supportScripts)
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.appendLog(result.text.isEmpty ? (result.ok ? "Helper installed" : "Install failed") : result.text)
                self.refreshHelperStatus()
                if result.ok {
                    self.statusText = "Helper installed — Connect Split no longer needs a password"
                }
            }
        }
    }

    func uninstallHelper() {
        isBusy = true
        Task.detached { [weak self] in
            let result = HelperService.uninstall()
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
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

    func confirmDisconnect() {
        showDisconnectConfirm = false
        restore()
    }

    func apply() {
        saveConfig()
        syncScriptsToSupport()
        runEngine(arguments: ["apply"]) { [weak self] ok, output in
            guard let self else { return }
            if ok || output.contains("split tunnel applied") || output.contains("hijack") {
                self.isActive = true
                self.statusText = "Split ON — VPN routes + bypass applied"
            }
        }
    }

    func restore() {
        runEngine(arguments: ["restore"]) { [weak self] ok, _ in
            guard let self else { return }
            if ok {
                self.isActive = false
                self.statusText = "Split OFF — Kerio session unchanged"
            }
        }
    }

    func refreshStatus() {
        runEngine(arguments: ["status"], preferUser: true) { [weak self] _, output in
            self?.appendLog(output)
            self?.statusText = "Status refreshed"
        }
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
        config.appearance = mode
        saveConfig()
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

    func saveConfig() {
        ensureWritableSupport()
        config.sanitize()
        do {
            try config.save(to: configURL)
            syncJsonFromConfig()
            jsonError = nil
            appendLog("Config saved → \(configURL.path)")
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
        if let data = try? String(contentsOf: state, encoding: .utf8),
           data.contains("APPLIED_AT=") {
            isActive = true
        }
    }

    private func ensureWritableSupport() {
        let root = supportRoot
        let configDir = root.appendingPathComponent("Config", isDirectory: true)
        if isWritable(root) {
            try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
            return
        }
        let uid = getuid()
        let path = root.path.replacingOccurrences(of: "'", with: "'\\''")
        _ = appleScriptAdmin(
            "mkdir -p '\(path)/Config' && chown -R \(uid):staff '\(path)' && chmod -R u+rwX '\(path)'"
        )
        try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
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
        isBusy = true
        let script = scriptURL.path
        let useHelper = !preferUser && (helperReady || HelperService.isInstalled)

        Task.detached { [weak self] in
            let result: (ok: Bool, text: String)
            if useHelper {
                // Ensure config path is visible to ctl via Application Support
                result = HelperService.runCtl(arguments)
            } else if preferUser || arguments.first == "status" {
                result = Self.runUserProcess(script: script, arguments: arguments)
            } else {
                let quotedScript = script.replacingOccurrences(of: "'", with: "'\\''")
                let args = arguments.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
                result = appleScriptAdmin("/bin/bash '\(quotedScript)' \(args) 2>&1")
            }

            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.appendLog(result.text.isEmpty ? (result.ok ? "OK" : "Failed") : result.text)
                if !result.ok {
                    self.statusText = "Action failed — see Activity"
                }
                completion?(result.ok, result.text)
            }
        }
    }

    private nonisolated static func runUserProcess(script: String, arguments: [String]) -> (ok: Bool, text: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script] + arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus == 0, text)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log = log.isEmpty ? trimmed : log + "\n———\n" + trimmed
    }
}
