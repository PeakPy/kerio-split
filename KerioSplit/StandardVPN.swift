import AppKit
import Foundation

/// Real OpenVPN / IPsec / L2TP helpers — **not** the Kerio proprietary protocol.
///
/// Official GFI docs (VPN section catalog):
/// - macOS native client: System Settings → L2TP over IPsec
///   https://support.keriocontrol.gfi.com/article/118441-configuring-ipsec-vpn-client-on-macos
/// - IPsec server (PSK or cert), simultaneous with Kerio VPN
///   https://support.keriocontrol.gfi.com/article/118416-configuring-ipsec-vpn-server
/// - OpenVPN since Kerio Control 9.5, profiles from user portal `:4081`
///   https://support.keriocontrol.gfi.com/article/123937-openvpn-integration-in-kerio-control
///
/// This type only drives tools that actually exist on the Mac:
/// `scutil --nc` (System Settings VPN), Tunnelblick/Viscosity, or an `openvpn` binary.
/// It never claims to speak Kerio TCP/4090.
struct StandardVPNStatus: Equatable {
    var scutilServices: [ScutilVPN]
    var openvpnBinary: String?
    var tunnelblickURL: URL?
    var viscosityURL: URL?

    static let empty = StandardVPNStatus(
        scutilServices: [],
        openvpnBinary: nil,
        tunnelblickURL: nil,
        viscosityURL: nil
    )

    var hasAnyPath: Bool {
        !scutilServices.isEmpty
            || openvpnBinary != nil
            || tunnelblickURL != nil
            || viscosityURL != nil
    }

    var summary: String {
        var parts: [String] = []
        let kerioNE = scutilServices.filter(\.isKerioNetworkExtension).count
        let other = scutilServices.count - kerioNE
        if other > 0 {
            parts.append("\(other) macOS VPN profile\(other == 1 ? "" : "s")")
        }
        if kerioNE > 0 {
            parts.append("\(kerioNE) Kerio NE profile (Connect All uses the official client, not scutil)")
        }
        if tunnelblickURL != nil { parts.append("Tunnelblick") }
        if viscosityURL != nil { parts.append("Viscosity") }
        if let bin = openvpnBinary { parts.append("openvpn at \(bin)") }
        if parts.isEmpty {
            return "No macOS VPN profile found. Add L2TP over IPsec in System Settings (GFI article 118441), or import a Kerio Control 9.5+ OpenVPN profile."
        }
        return parts.joined(separator: " · ")
    }
}

struct ScutilVPN: Equatable, Identifiable {
    var id: String { uuid.isEmpty ? name : uuid }
    var uuid: String
    var name: String
    var state: String
    /// Provider from `scutil --nc list`, e.g. `com.kerio.VPN.fr.agent`.
    var plugin: String

    /// Kerio’s Network Extension profile. `scutil --nc start` fails on it (internal error).
    var isKerioNetworkExtension: Bool {
        let hay = "\(plugin) \(name)".lowercased()
        return hay.contains("com.kerio.vpn") || hay.contains("keriovpnnetext")
    }
}

enum StandardVPN {
    private static let openvpnCandidates = [
        "/opt/homebrew/sbin/openvpn",
        "/opt/homebrew/bin/openvpn",
        "/usr/local/sbin/openvpn",
        "/usr/local/bin/openvpn"
    ]

    static func probe() -> StandardVPNStatus {
        let list = HelperService.runProcess("/usr/sbin/scutil", ["--nc", "list"], timeoutSeconds: 3).text
        return StandardVPNStatus(
            scutilServices: parseScutilList(list),
            openvpnBinary: locateOpenVPN(),
            tunnelblickURL: appURL(bundleID: "net.tunnelblick.tunnelblick", path: "/Applications/Tunnelblick.app"),
            viscosityURL: appURL(bundleID: "com.viscosityvpn.Viscosity", path: "/Applications/Viscosity.app")
        )
    }

    static func connectSystemVPN(named name: String) -> (ok: Bool, message: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Pick a macOS VPN profile. Create L2TP over IPsec in System Settings first (https://support.keriocontrol.gfi.com/article/118441-configuring-ipsec-vpn-client-on-macos).")
        }
        // Proven on this Mac: scutil start on com.kerio.VPN.fr.agent fails with an internal error.
        let listed = probe().scutilServices
        if listed.contains(where: { $0.name == trimmed && $0.isKerioNetworkExtension })
            || trimmed.lowercased().contains("kerio") {
            return (
                false,
                "scutil cannot start the Kerio Network Extension profile “\(trimmed)”. Use Connect All with the official Kerio client."
            )
        }
        let result = HelperService.runProcess(
            "/usr/sbin/scutil",
            ["--nc", "start", trimmed],
            timeoutSeconds: 8
        )
        if result.ok {
            return (true, "Started macOS VPN “\(trimmed)” via scutil — waiting for utun.")
        }
        let detail = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            false,
            detail.isEmpty
                ? "scutil could not start “\(trimmed)”. Create the IPsec/IKEv2 profile in System Settings first."
                : detail
        )
    }

    static func stopSystemVPN(named name: String) -> (ok: Bool, message: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, "No macOS VPN name to stop.") }
        let result = HelperService.runProcess(
            "/usr/sbin/scutil",
            ["--nc", "stop", trimmed],
            timeoutSeconds: 8
        )
        return (result.ok, result.ok ? "Stopped macOS VPN “\(trimmed)”." : result.text)
    }

    static func stopOpenVPN() -> (ok: Bool, message: String) {
        let source = """
        tell application "System Events"
            if exists process "Tunnelblick" then
                try
                    tell application "Tunnelblick" to disconnect all
                    return "OK:Tunnelblick"
                on error errMsg
                    return "ERR:" & errMsg
                end try
            end if
            if exists process "Viscosity" then
                try
                    tell application "Viscosity" to disconnectall
                    return "OK:Viscosity"
                on error errMsg
                    return "ERR:" & errMsg
                end try
            end if
            return "NO_APP"
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "\(error)"
            return (false, "Could not stop OpenVPN: \(msg). Disconnect in Tunnelblick or Viscosity.")
        }
        let text = (result?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("OK:") {
            let app = String(text.dropFirst("OK:".count))
            return (true, "Disconnected \(app).")
        }
        if text.hasPrefix("ERR:") {
            return (false, "\(String(text.dropFirst("ERR:".count))). Disconnect in Tunnelblick or Viscosity.")
        }
        return (false, "Tunnelblick/Viscosity is not running. Disconnect there if OpenVPN is still up.")
    }

    /// Opens a `.ovpn` in Tunnelblick/Viscosity if installed. Does not run `openvpn` as root.
    static func openOpenVPNProfile(_ path: String, status: StandardVPNStatus) -> (ok: Bool, message: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Choose a .ovpn from the Kerio Control user portal (https://<firewall>:4081).")
        }
        let url = URL(fileURLWithPath: trimmed)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return (false, "OpenVPN profile not readable: \(trimmed)")
        }

        if let app = status.tunnelblickURL ?? status.viscosityURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            var opened = false
            let group = DispatchGroup()
            group.enter()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
                opened = (error == nil)
                group.leave()
            }
            _ = group.wait(timeout: .now() + 8)
            let label = app.deletingPathExtension().lastPathComponent
            return (
                opened,
                opened
                    ? "Opened \(url.lastPathComponent) in \(label) — connect there, then split applies when utun appears."
                    : "Could not open the profile in \(label)."
            )
        }

        if let bin = status.openvpnBinary {
            return (
                false,
                "Found \(bin), but OpenVPN needs root for utun and Kerio Split will not run it via the route helper. Install Tunnelblick, or import the profile in System Settings."
            )
        }

        return (
            false,
            "No OpenVPN GUI found. Install Tunnelblick (https://tunnelblick.net) or add an IPsec/IKEv2 VPN in System Settings. Kerio Control 9.5+ serves .ovpn files at :4081."
        )
    }

    static func parseScutilList(_ text: String) -> [ScutilVPN] {
        var items: [ScutilVPN] = []
        let uuidRegex = try? NSRegularExpression(
            pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        )
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let lower = line.lowercased()
            guard lower.contains("connected")
                    || lower.contains("disconnected")
                    || lower.contains("connecting") else { continue }

            var state = "unknown"
            if lower.contains("(connected)") { state = "Connected" }
            else if lower.contains("(connecting)") { state = "Connecting" }
            else if lower.contains("(disconnected)") { state = "Disconnected" }

            var uuid = ""
            if let regex = uuidRegex,
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range, in: line) {
                uuid = String(line[range])
            }
            var name = ""
            if let first = line.firstIndex(of: "\""),
               let last = line.lastIndex(of: "\""),
               first < last {
                name = String(line[line.index(after: first)..<last])
            }
            if name.isEmpty { name = uuid }
            guard !name.isEmpty else { continue }

            var plugin = ""
            if let open = line.range(of: "VPN ("),
               let close = line[open.upperBound...].firstIndex(of: ")") {
                plugin = String(line[open.upperBound..<close])
            } else if let marker = line.range(of: "[VPN:"),
                      let close = line[marker.upperBound...].firstIndex(of: "]") {
                plugin = String(line[marker.upperBound..<close])
            }
            items.append(ScutilVPN(uuid: uuid, name: name, state: state, plugin: plugin))
        }
        return items
    }

    private static func locateOpenVPN() -> String? {
        for path in openvpnCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = HelperService.runProcess("/usr/bin/which", ["openvpn"], timeoutSeconds: 2)
        let path = which.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if which.ok, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func appURL(bundleID: String, path: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
