import Foundation
import AppKit

enum HelperService {
    static let ctlPath = "/usr/local/libexec/keriosplit-ctl"
    static let sudoersPath = "/etc/sudoers.d/keriosplit"

    static var filesPresent: Bool {
        FileManager.default.isExecutableFile(atPath: ctlPath)
            && FileManager.default.fileExists(atPath: sudoersPath)
    }

    static var isInstalled: Bool { filesPresent }

    /// Must be called off the main thread. Uses `ping`, not `status`, so a missing
    /// Kerio tunnel cannot look like a broken helper.
    static func canRunPasswordless() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: ctlPath) else { return false }
        return runProcess(
            "/usr/bin/sudo",
            ["-n", ctlPath, "ping"],
            timeoutSeconds: 4
        ).ok
    }

    /// Off the main thread. Explains why passwordless sudo is not working.
    static func diagnose() -> String {
        var lines: [String] = []
        let user = NSUserName()
        lines.append("macOS user: \(user)")
        lines.append("ctl: \(ctlPath) \(FileManager.default.isExecutableFile(atPath: ctlPath) ? "present" : "MISSING")")
        lines.append("sudoers: \(sudoersPath) \(FileManager.default.fileExists(atPath: sudoersPath) ? "present" : "MISSING")")

        if FileManager.default.isExecutableFile(atPath: ctlPath) {
            let ping = runProcess("/usr/bin/sudo", ["-n", ctlPath, "ping"], timeoutSeconds: 4)
            if ping.ok {
                lines.append("sudo -n ping: OK")
            } else {
                let text = ping.text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("sudo -n ping: FAILED")
                if !text.isEmpty { lines.append(text) }
                lines.append("Fix: tap Allow once so sudoers is written for \(user), not root.")
            }
        } else {
            lines.append("Helper is not installed. Connect All must not be used until Allow once succeeds.")
        }
        return lines.joined(separator: "\n")
    }

    /// Must be called off the main thread.
    static func runCtl(_ arguments: [String]) -> (ok: Bool, text: String) {
        guard FileManager.default.isExecutableFile(atPath: ctlPath) else {
            return (false, "Helper not installed — tap Allow once first")
        }
        let result = runProcess("/usr/bin/sudo", ["-n", ctlPath] + arguments, timeoutSeconds: 20)
        if result.ok { return result }
        if result.text.contains("password is required") || result.text.contains("a terminal is required") {
            return (false, "Passwordless helper is not active.\n\(diagnose())")
        }
        return result
    }

    static func install(scriptPath: String, userName: String) -> (ok: Bool, text: String) {
        guard FileManager.default.isReadableFile(atPath: scriptPath) else {
            return (false, "Installer missing at \(scriptPath)")
        }
        let elevated = runAdmin(userName: userName, scriptPath: scriptPath)
        guard elevated.ok else {
            return (false, elevated.text.isEmpty ? "Allow once was cancelled or failed" : elevated.text)
        }

        // Proof, from this user, without AppleScript: sudoers actually matches.
        let ping = runProcess("/usr/bin/sudo", ["-n", ctlPath, "ping"], timeoutSeconds: 4)
        if ping.ok {
            return (true, elevated.text)
        }
        let extra = ping.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            false,
            """
            Installer ran but passwordless sudo still fails for \(userName).
            \(elevated.text)
            \(extra)
            \(diagnose())
            """
        )
    }

    /// Must run on the main thread — shows the macOS password dialog.
    @MainActor
    static func installOnMainThread(scriptPath: String, userName: String) -> (ok: Bool, text: String) {
        install(scriptPath: scriptPath, userName: userName)
    }

    @MainActor
    static func uninstallOnMainThread() -> (ok: Bool, text: String) {
        uninstall()
    }

    static func uninstall() -> (ok: Bool, text: String) {
        let source = """
        do shell script "rm -f '\(ctlPath)' '\(sudoersPath)' && echo uninstalled" with administrator privileges
        """
        return runAppleScript(source)
    }

    /// Blocking process runner — call only from a background queue.
    static func runProcess(_ exe: String, _ args: [String], timeoutSeconds: TimeInterval = 30) -> (ok: Bool, text: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                group.leave()
            }
            let waitResult = group.wait(timeout: .now() + timeoutSeconds)
            if waitResult == .timedOut {
                proc.terminate()
                _ = group.wait(timeout: .now() + 1)
                return (false, "Timed out after \(Int(timeoutSeconds))s")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus == 0, text)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Apple TN2065: use `quoted form of` and `with administrator privileges` (not sudo).
    /// Pass INSTALL_USER explicitly — elevation does not set SUDO_USER.
    private static func runAdmin(userName: String, scriptPath: String) -> (ok: Bool, text: String) {
        let source = """
        set envUser to "\(appleEscape(userName))"
        set scriptPath to "\(appleEscape(scriptPath))"
        do shell script "INSTALL_USER=" & quoted form of envUser & " /bin/bash " & quoted form of scriptPath with administrator privileges
        """
        return runAppleScript(source)
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
