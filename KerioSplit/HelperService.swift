import Foundation
import AppKit

enum HelperService {
    static let ctlPath = "/usr/local/libexec/keriosplit-ctl"
    static let sudoersPath = "/etc/sudoers.d/keriosplit"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ctlPath)
            && FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// Must be called off the main thread.
    static func canRunPasswordless() -> Bool {
        guard isInstalled else { return false }
        return runProcess(
            "/usr/bin/sudo",
            ["-n", ctlPath, "status"],
            timeoutSeconds: 3
        ).ok
    }

    /// Must be called off the main thread (except the AppleScript fallback, which shows a UI prompt).
    static func runCtl(_ arguments: [String]) -> (ok: Bool, text: String) {
        guard FileManager.default.isExecutableFile(atPath: ctlPath) else {
            return (false, "Helper not installed")
        }
        if FileManager.default.fileExists(atPath: sudoersPath) {
            return runProcess("/usr/bin/sudo", ["-n", ctlPath] + arguments, timeoutSeconds: 20)
        }
        let joined = ([ctlPath] + arguments)
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        return appleScriptAdmin("/usr/bin/sudo \(joined) 2>&1")
    }

    static func install(fromBundleScripts scriptsDir: URL) -> (ok: Bool, text: String) {
        let installScript = scriptsDir.appendingPathComponent("install-helper.sh")
        let path = installScript.path.replacingOccurrences(of: "'", with: "'\\''")
        return appleScriptAdmin("/bin/bash '\(path)' 2>&1")
    }

    static func uninstall() -> (ok: Bool, text: String) {
        let shell = """
        rm -f '\(ctlPath)' '\(sudoersPath)' && echo uninstalled
        """
        return appleScriptAdmin(shell)
    }

    /// Blocking process runner — call only from a background queue.
    static func runProcess(_ exe: String, _ args: [String], timeoutSeconds: TimeInterval = 30) -> (ok: Bool, text: String) {
        // Call only from a background queue — never block the UI / mouse cursor.
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
