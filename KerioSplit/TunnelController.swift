import Foundation
import AppKit
import Combine
import Darwin

@MainActor
final class TunnelController: ObservableObject {
    @Published var isActive = false
    @Published var isBusy = false
    @Published var statusText = "Connect Kerio, then enable split tunneling"
    @Published var targetsText = ""
    @Published var log = ""

    private let fileManager = FileManager.default

    /// Bundled scripts/config inside the .app (read-only).
    private var bundleRoot: URL {
        if let env = ProcessInfo.processInfo.environment["KERIOSPLIT_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("KerioSplitBundle", isDirectory: true),
           fileManager.fileExists(atPath: bundled.appendingPathComponent("Scripts/split-tunnel.sh").path) {
            return bundled
        }
        // Dev checkout
        let downloads = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/KerioSplit", isDirectory: true)
        if fileManager.fileExists(atPath: downloads.appendingPathComponent("Scripts/split-tunnel.sh").path) {
            return downloads
        }
        return bundledFallbackSupport
    }

    /// Writable user config (targets + state).
    private var supportRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KerioSplit", isDirectory: true)
    }

    private var bundledFallbackSupport: URL { supportRoot }

    private var scriptURL: URL { bundleRoot.appendingPathComponent("Scripts/split-tunnel.sh") }
    private var targetsURL: URL { supportRoot.appendingPathComponent("Config/targets.txt") }
    private var bundledTargetsURL: URL { bundleRoot.appendingPathComponent("Config/targets.txt") }

    func onAppear() {
        ensureWritableSupport()
        loadTargets()
        detectAppliedFromVerify()
    }

    func toggle() {
        if isActive { restore() } else { apply() }
    }

    func apply() {
        saveTargets()
        runAdmin(arguments: ["apply"]) { [weak self] ok, output in
            guard let self else { return }
            if ok || output.contains("hijack present: no") {
                self.isActive = true
                self.statusText = "Split ON — SSH via Kerio · internet via Wi‑Fi"
            }
        }
    }

    func restore() {
        runAdmin(arguments: ["restore"]) { [weak self] ok, _ in
            guard let self else { return }
            if ok {
                self.isActive = false
                self.statusText = "Split OFF — Kerio session unchanged"
            }
        }
    }

    func refreshStatus() {
        runUser(arguments: ["status"]) { [weak self] output in
            guard let self else { return }
            self.isBusy = false
            self.appendLog(output)
            self.statusText = "Status refreshed — see activity log"
        }
    }

    func saveTargets() {
        ensureWritableSupport()
        let data = targetsText.data(using: .utf8) ?? Data()
        try? data.write(to: targetsURL, options: .atomic)
        appendLog("Targets saved")
    }

    // MARK: - Support folder (admin UI, no Terminal)

    private func ensureWritableSupport() {
        let root = supportRoot
        let config = root.appendingPathComponent("Config", isDirectory: true)

        if isWritable(root) {
            try? fileManager.createDirectory(at: config, withIntermediateDirectories: true)
            seedTargetsIfNeeded()
            return
        }

        // Reclaim root-owned folder via macOS password dialog
        let uid = getuid()
        let path = root.path.replacingOccurrences(of: "'", with: "'\\''")
        let shell = """
        mkdir -p '\(path)/Config' && chown -R \(uid):staff '\(path)' && chmod -R u+rwX '\(path)'
        """
        _ = runAppleScriptAdmin(shell)
        try? fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        seedTargetsIfNeeded()
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

    private func seedTargetsIfNeeded() {
        guard !fileManager.fileExists(atPath: targetsURL.path) else { return }
        if let data = try? Data(contentsOf: bundledTargetsURL) {
            try? data.write(to: targetsURL, options: .atomic)
        } else {
            try? "192.168.70.0/24\n".write(to: targetsURL, atomically: true, encoding: .utf8)
        }
    }

    private func loadTargets() {
        if let data = try? Data(contentsOf: targetsURL),
           let text = String(data: data, encoding: .utf8) {
            targetsText = text
        } else if let data = try? Data(contentsOf: bundledTargetsURL),
                  let text = String(data: data, encoding: .utf8) {
            targetsText = text
        } else {
            targetsText = "192.168.70.0/24\n"
        }
    }

    private func detectAppliedFromVerify() {
        let state = supportRoot.appendingPathComponent("saved-routes.env")
        if let data = try? String(contentsOf: state, encoding: .utf8),
           data.contains("APPLIED_AT=") {
            isActive = true
            statusText = "Split may be active — tap Connect to refresh"
        }
    }

    // MARK: - Script runners

    private func runAdmin(arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
        isBusy = true
        let script = scriptURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let args = arguments.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
        let shell = "/bin/bash '\(script)' \(args) 2>&1"
        Task.detached { [weak self] in
            let output = appleScriptAdmin(shell)
            let ok = output.ok
            let text = output.text
            let captured = self
            await MainActor.run {
                guard let captured else { return }
                captured.isBusy = false
                if ok {
                    captured.appendLog(text.isEmpty ? "Done." : text)
                    completion?(true, text)
                } else {
                    captured.appendLog("ERROR: \(text)")
                    captured.statusText = "Action failed — check the log"
                    completion?(false, text)
                }
            }
        }
    }

    private func runUser(arguments: [String], completion: @escaping (String) -> Void) {
        isBusy = true
        let script = scriptURL.path
        Task.detached {
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
                await MainActor.run { completion(text) }
            } catch {
                await MainActor.run { completion("ERROR: \(error.localizedDescription)") }
            }
        }
    }

    @discardableResult
    private func runAppleScriptAdmin(_ shell: String) -> Bool {
        appleScriptAdmin(shell).ok
    }

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log = log.isEmpty ? trimmed : log + "\n———\n" + trimmed
    }
}

private func appleScriptAdmin(_ shell: String) -> (ok: Bool, text: String) {
    let escaped = shell
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(escaped)\" with administrator privileges"
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
        let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "\(error)"
        return (false, msg)
    }
    return (true, result?.stringValue ?? "")
}
