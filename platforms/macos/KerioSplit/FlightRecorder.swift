import Foundation

/// Persistent, copy-friendly diagnostic trail so a pasted log reveals full app behavior.
enum FlightRecorder {
    static let isDiagBuild = false

    private static let queue = DispatchQueue(label: "dev.ehsanakbari.KerioSplit.flight")
    private static var lines: [String] = []
    private static let maxLines = 4000
    private static var sessionID = UUID().uuidString.prefix(8).lowercased()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KerioSplit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flight-recorder.log")
    }

    static func bootstrap(version: String) {
        sessionID = UUID().uuidString.prefix(8).lowercased()
        log(
            "boot",
            "session_start",
            [
                "session": String(sessionID),
                "version": version,
                "diag": isDiagBuild ? "1" : "0",
                "bundle": Bundle.main.bundlePath,
                "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                "os": ProcessInfo.processInfo.operatingSystemVersionString
            ]
        )
    }

    static func log(_ category: String, _ event: String, _ fields: [String: String] = [:]) {
        let stamp = iso.string(from: Date())
        var parts: [String] = ["[\(stamp)]", "sid=\(sessionID)", "cat=\(category)", "evt=\(event)"]
        for key in fields.keys.sorted() {
            let raw = fields[key] ?? ""
            let safe = raw
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "|", with: "/")
            parts.append("\(key)=\(safe)")
        }
        let line = parts.joined(separator: " | ")
        queue.async {
            lines.append(line)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            if let data = (line + "\n").data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: logURL, options: .atomic)
                }
            }
        }
    }

    /// Full export for pasting into chat — includes header + in-memory + on-disk tail.
    static func exportText(extra: String = "") -> String {
        queue.sync {
            var out: [String] = []
            out.append("===== Kerio Split Flight Recorder =====")
            out.append("session=\(sessionID) diag=\(isDiagBuild) path=\(logURL.path)")
            out.append("exported_at=\(iso.string(from: Date()))")
            out.append("NOTE: Paste this whole block. It is designed so failures are readable without the app.")
            out.append("----- session buffer (\(lines.count) lines) -----")
            out.append(contentsOf: lines)
            if let disk = try? String(contentsOf: logURL, encoding: .utf8), !disk.isEmpty {
                let diskLines = disk.split(separator: "\n", omittingEmptySubsequences: false).suffix(800)
                out.append("----- disk tail (\(diskLines.count) lines) -----")
                out.append(contentsOf: diskLines.map(String.init))
            }
            if !extra.isEmpty {
                out.append("----- extra snapshot -----")
                out.append(extra)
            }
            out.append("===== end flight recorder =====")
            return out.joined(separator: "\n")
        }
    }

    static var filePath: String { logURL.path }

    static func clearSessionBuffer() {
        queue.async {
            lines.removeAll(keepingCapacity: true)
        }
        log("boot", "buffer_cleared", [:])
    }
}
