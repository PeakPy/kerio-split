import Foundation

/// Snapshot of the official Kerio Control VPN Client config on this Mac.
///
/// Kerio Split is **not** a Kerio VPN protocol client. The proprietary protocol
/// (TCP 4090 TLS control + UDP AES-GCM data) has no public packet spec, and
/// `libkvnet` is only the virtual NIC layer. This helper only reads/writes
/// XML fields that GFI documents for `~/.kerio/vpnclient/user.cfg`.
///
/// Documented schema (GFI manuals):
/// https://manuals.gfi.com/en/kerio/control/content/vpn/deleting-vpn-client-entries-on-os-x-1583.html
///
/// ```
/// <connection type="user">
///   <description></description>
///   <server>vpn.com</server>
///   <username>jsmith</username>
///   <password></password>
///   <savePassword>0</savePassword>
///   <persistent>0</persistent>
/// </connection>
/// ```
///
/// Persistent mode also requires Save password in the official UI:
/// https://support.keriocontrol.gfi.com/article/118581-configuring-kerio-control-vpn-client-in-macos
///
/// Password storage uses an undocumented `D3S:` blob. This type never writes,
/// encodes, or logs password text.
struct KerioSavedConnection: Equatable {
    var configExists: Bool
    var server: String
    var hasPassword: Bool
    var savePassword: Bool
    var persistent: Bool

    static let empty = KerioSavedConnection(
        configExists: false,
        server: "",
        hasPassword: false,
        savePassword: false,
        persistent: false
    )

    var canEnablePersistent: Bool {
        configExists && hasPassword
    }

    var statusLine: String {
        guard configExists else {
            return "No ~/.kerio/vpnclient/user.cfg — install Kerio Control VPN Client and save a connection first."
        }
        var parts: [String] = []
        if !server.isEmpty { parts.append(server) }
        parts.append(hasPassword ? "password saved" : "password not saved")
        parts.append(persistent ? "persistent ON" : "persistent OFF")
        return parts.joined(separator: " · ")
    }
}

enum KerioClientConfig {
    static var userCfgURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kerio/vpnclient/user.cfg")
    }

    static func snapshot() -> KerioSavedConnection {
        let url = userCfgURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .empty
        }
        guard let xml = try? XMLDocument(contentsOf: url, options: [.nodePreserveAll]),
              let root = xml.rootElement() else {
            return KerioSavedConnection(
                configExists: true,
                server: "",
                hasPassword: false,
                savePassword: false,
                persistent: false
            )
        }

        let conn = root.elements(forName: "connections").first?
            .elements(forName: "connection").first
        let passwordText = childText(conn, "password")
        return KerioSavedConnection(
            configExists: true,
            server: childText(conn, "server"),
            hasPassword: !passwordText.isEmpty,
            savePassword: isTruthy(childText(conn, "savePassword")),
            persistent: isTruthy(childText(conn, "persistent"))
        )
    }

    /// Sets documented `<persistent>` / `<savePassword>` flags only.
    /// Does not create connections, invent fingerprints, or touch `<password>`.
    static func setPersistent(_ enabled: Bool) -> (ok: Bool, message: String) {
        let url = userCfgURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return (false, "Kerio user.cfg not found. Install Kerio Control VPN Client and save a connection first.")
        }

        let xml: XMLDocument
        do {
            xml = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        } catch {
            return (false, "Could not parse user.cfg as XML.")
        }
        guard let root = xml.rootElement(),
              let connections = root.elements(forName: "connections").first else {
            return (false, "user.cfg has no <connections> block (unexpected format).")
        }

        let nodes = connections.elements(forName: "connection")
        guard !nodes.isEmpty else {
            return (false, "user.cfg has no <connection> entries. Save a connection in the Kerio client first.")
        }

        if enabled {
            let anyPassword = nodes.contains { !childText($0, "password").isEmpty }
            guard anyPassword else {
                return (
                    false,
                    "Persistent needs a saved password. In Kerio VPN Client: check Save password, connect once, then try again. Kerio Split will not encode passwords (D3S is undocumented)."
                )
            }
        }

        do {
            try backup(url)
        } catch {
            return (false, "Could not back up user.cfg before editing.")
        }

        for conn in nodes {
            if enabled {
                setChild(conn, "savePassword", "1")
                setChild(conn, "persistent", "1")
            } else {
                setChild(conn, "persistent", "0")
            }
        }

        do {
            let data = xml.xmlData(options: [.nodePrettyPrint])
            try data.write(to: url, options: .atomic)
        } catch {
            return (false, "Failed to write user.cfg: \(error.localizedDescription)")
        }

        if enabled {
            return (
                true,
                "Wrote persistent=1 and savePassword=1 in user.cfg. Open Kerio, unlock the padlock if asked, and click Connect once — the official client keeps the tunnel after that (including reboot)."
            )
        }
        return (true, "Wrote persistent=0 in user.cfg. Kerio will no longer auto-reconnect after reboot.")
    }

    private static func childText(_ parent: XMLElement?, _ name: String) -> String {
        guard let parent else { return "" }
        return parent.elements(forName: name).first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isTruthy(_ raw: String) -> Bool {
        raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
    }

    private static func setChild(_ parent: XMLElement, _ name: String, _ value: String) {
        if let existing = parent.elements(forName: name).first {
            existing.stringValue = value
            return
        }
        parent.addChild(XMLElement(name: name, stringValue: value))
    }

    private static func backup(_ url: URL) throws {
        let bak = url.deletingLastPathComponent().appendingPathComponent("user.cfg.keriosplit.bak")
        if FileManager.default.fileExists(atPath: bak.path) {
            try FileManager.default.removeItem(at: bak)
        }
        try FileManager.default.copyItem(at: url, to: bak)
    }
}
