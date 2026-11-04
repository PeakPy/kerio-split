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
            timeoutSeconds: 6
        ).ok
    }

    enum Probe { case ready, notInstalled, passwordRequired, unknown }

    /// Off the main thread. Distinguishes "sudo said no" from "sudo was slow / errored":
    /// a timeout during VPN churn must not look like a missing helper.
    static func probe() -> Probe {
        guard FileManager.default.isExecutableFile(atPath: ctlPath),
              FileManager.default.fileExists(atPath: sudoersPath) else { return .notInstalled }
        let r = runProcess("/usr/bin/sudo", ["-n", ctlPath, "ping"], timeoutSeconds: 10)
        if r.ok { return .ready }
        if r.text.contains("password is required") || r.text.contains("a terminal is required")
            || r.text.contains("not in the sudoers") || r.text.contains("may not run sudo") {
            return .passwordRequired
        }
        return .unknown
    }

    /// Off the main thread. Explains why passwordless sudo is not working.
    static func diagnose() -> String {
        var lines: [String] = []
        let user = NSUserName()
        lines.append("macOS user: \(user)")
        lines.append("ctl: \(ctlPath) \(FileManager.default.isExecutableFile(atPath: ctlPath) ? "present" : "MISSING")")
        lines.append("sudoers: \(sudoersPath) \(FileManager.default.fileExists(atPath: sudoersPath) ? "present" : "MISSING")")

        if FileManager.default.isExecutableFile(atPath: ctlPath) {
            let ping = runProcess("/usr/bin/sudo", ["-n", ctlPath, "ping"], timeoutSeconds: 2)
            if ping.ok {
                lines.append("sudo -n ping: OK")
            } else {
                let text = ping.text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("sudo -n ping: FAILED")
                if !text.isEmpty { lines.append(text) }
                lines.append("Fix: install the route helper so sudoers is written for \(user), not root.")
            }
        } else {
            lines.append("Helper is not installed. Connect All must not be used until the route helper is installed.")
        }
        return lines.joined(separator: "\n")
    }

    /// Must be called off the main thread.
    static func runCtl(_ arguments: [String]) -> (ok: Bool, text: String) {
        guard FileManager.default.isExecutableFile(atPath: ctlPath) else {
            return (false, "Helper not installed — install the route helper first")
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
            return (false, elevated.text.isEmpty ? "Route helper install was cancelled or failed" : elevated.text)
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
    /// Output is collected by a readability handler and exit by a termination handler, so a hung child
    /// can never park extra GCD threads (a saturated pool made every network probe read "nothing").
    static func runProcess(_ exe: String, _ args: [String], timeoutSeconds: TimeInterval = 30) -> (ok: Bool, text: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        let output = OutputBox()
        let exited = DispatchSemaphore(value: 0)
        let eof = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                output.append(chunk)
            }
        }
        proc.terminationHandler = { _ in exited.signal() }

        func cleanup() {
            reader.readabilityHandler = nil
            try? reader.close()
            try? pipe.fileHandleForWriting.close()
        }

        do {
            try proc.run()
        } catch {
            cleanup()
            return (false, error.localizedDescription)
        }
        // The child owns the write end now; drop ours so EOF can arrive.
        try? pipe.fileHandleForWriting.close()

        if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            proc.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            cleanup()
            return (false, "Timed out after \(Int(timeoutSeconds))s")
        }
        _ = eof.wait(timeout: .now() + 1)
        cleanup()
        return (proc.terminationStatus == 0, String(data: output.snapshot(), encoding: .utf8) ?? "")
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
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
