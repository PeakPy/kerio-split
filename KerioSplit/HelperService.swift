import Foundation
import AppKit

enum HelperService {
    static let ctlPath = "/usr/local/libexec/keriosplit-ctl"
    static let sudoersPath = "/etc/sudoers.d/keriosplit"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ctlPath)
            && FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// `sudo -n` succeeds without password when helper is installed.
    static func canRunPasswordless() -> Bool {
        guard isInstalled else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", ctlPath, "status"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func runCtl(_ arguments: [String]) -> (ok: Bool, text: String) {
        if canRunPasswordless() {
            return runProcess("/usr/bin/sudo", ["-n", ctlPath] + arguments)
        }
        // Fallback: one admin prompt
        let joined = ([ctlPath] + arguments)
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        // Prefer ctl if present even without sudoers
        if FileManager.default.isExecutableFile(atPath: ctlPath) {
            return appleScriptAdmin("/usr/bin/sudo \(joined) 2>&1")
        }
        return (false, "Helper not installed")
    }

    static func install(fromBundleScripts scriptsDir: URL) -> (ok: Bool, text: String) {
        let installScript = scriptsDir.appendingPathComponent("install-helper.sh")
        let path = installScript.path.replacingOccurrences(of: "'", with: "'\\''")
        // Copy repo root expectation: install-helper uses ROOT=parent of Scripts
        return appleScriptAdmin("/bin/bash '\(path)' 2>&1")
    }

    static func uninstall() -> (ok: Bool, text: String) {
        let shell = """
        rm -f '\(ctlPath)' '\(sudoersPath)' && echo uninstalled
        """
        return appleScriptAdmin(shell)
    }

    private static func runProcess(_ exe: String, _ args: [String]) -> (ok: Bool, text: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
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
}

func appleScriptAdmin(_ shell: String) -> (ok: Bool, text: String) {
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
