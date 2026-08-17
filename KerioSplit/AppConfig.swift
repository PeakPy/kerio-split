import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How Connect All brings a tunnel up. Kerio proprietary protocol is never spoken here.
enum ConnectBackend: String, Codable, CaseIterable, Identifiable {
    case kerioClient
    case systemVPN
    case openvpnProfile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kerioClient: return "Kerio Control VPN Client"
        case .systemVPN: return "macOS VPN (IPsec / IKEv2)"
        case .openvpnProfile: return "OpenVPN profile"
        }
    }

    var subtitle: String {
        switch self {
        case .kerioClient:
            return "Starts official Kerio client, then split. Kerio Split cannot log in or speak Kerio’s protocol."
        case .systemVPN:
            return "Starts a System Settings L2TP/IPsec VPN via scutil (GFI: article 118441). Admin must enable IPsec on Kerio Control."
        case .openvpnProfile:
            return "Opens a .ovpn from Kerio Control 9.5+ user portal (:4081) in Tunnelblick/Viscosity."
        }
    }
}

struct AppConfig: Codable, Equatable {
    var vpnRoutes: [String]
    var bypassRoutes: [String]
    var options: Options
    var appearance: AppearanceMode

    struct Options: Codable, Equatable {
        var removeFullTunnel: Bool
        var restoreLanDefault: Bool
        var restoreLanDns: Bool
        var customDns: [String]
        var autoApplyOnLaunch: Bool
        var autoApplyWhenKerioConnects: Bool
        var confirmBeforeDisconnect: Bool
        var launchAtLogin: Bool
        var showMenuBar: Bool
        var notifyOnChange: Bool
        var connectBackend: ConnectBackend
        var systemVPNName: String
        var openvpnConfigPath: String

        static let `default` = Options(
            removeFullTunnel: true,
            restoreLanDefault: true,
            restoreLanDns: true,
            customDns: [],
            autoApplyOnLaunch: false,
            autoApplyWhenKerioConnects: true,
            confirmBeforeDisconnect: true,
            launchAtLogin: false,
            showMenuBar: true,
            notifyOnChange: true,
            connectBackend: .kerioClient,
            systemVPNName: "",
            openvpnConfigPath: ""
        )

        init(
            removeFullTunnel: Bool,
            restoreLanDefault: Bool,
            restoreLanDns: Bool,
            customDns: [String],
            autoApplyOnLaunch: Bool,
            autoApplyWhenKerioConnects: Bool,
            confirmBeforeDisconnect: Bool,
            launchAtLogin: Bool,
            showMenuBar: Bool,
            notifyOnChange: Bool,
            connectBackend: ConnectBackend,
            systemVPNName: String,
            openvpnConfigPath: String
        ) {
            self.removeFullTunnel = removeFullTunnel
            self.restoreLanDefault = restoreLanDefault
            self.restoreLanDns = restoreLanDns
            self.customDns = customDns
            self.autoApplyOnLaunch = autoApplyOnLaunch
            self.autoApplyWhenKerioConnects = autoApplyWhenKerioConnects
            self.confirmBeforeDisconnect = confirmBeforeDisconnect
            self.launchAtLogin = launchAtLogin
            self.showMenuBar = showMenuBar
            self.notifyOnChange = notifyOnChange
            self.connectBackend = connectBackend
            self.systemVPNName = systemVPNName
            self.openvpnConfigPath = openvpnConfigPath
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            removeFullTunnel = try c.decodeIfPresent(Bool.self, forKey: .removeFullTunnel) ?? true
            restoreLanDefault = try c.decodeIfPresent(Bool.self, forKey: .restoreLanDefault) ?? true
            restoreLanDns = try c.decodeIfPresent(Bool.self, forKey: .restoreLanDns) ?? true
            customDns = try c.decodeIfPresent([String].self, forKey: .customDns) ?? []
            autoApplyOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoApplyOnLaunch) ?? false
            autoApplyWhenKerioConnects = try c.decodeIfPresent(Bool.self, forKey: .autoApplyWhenKerioConnects) ?? true
            confirmBeforeDisconnect = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDisconnect) ?? true
            launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
            showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
            notifyOnChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnChange) ?? true
            connectBackend = try c.decodeIfPresent(ConnectBackend.self, forKey: .connectBackend) ?? .kerioClient
            systemVPNName = try c.decodeIfPresent(String.self, forKey: .systemVPNName) ?? ""
            openvpnConfigPath = try c.decodeIfPresent(String.self, forKey: .openvpnConfigPath) ?? ""
        }
    }

    static let `default` = AppConfig(
        vpnRoutes: ["192.168.70.0/24"],
        bypassRoutes: [],
        options: .default,
        appearance: .system
    )

    init(vpnRoutes: [String], bypassRoutes: [String], options: Options, appearance: AppearanceMode) {
        self.vpnRoutes = vpnRoutes
        self.bypassRoutes = bypassRoutes
        self.options = options
        self.appearance = appearance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vpnRoutes = try c.decodeIfPresent([String].self, forKey: .vpnRoutes) ?? []
        bypassRoutes = try c.decodeIfPresent([String].self, forKey: .bypassRoutes) ?? []
        options = try c.decodeIfPresent(Options.self, forKey: .options) ?? .default
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
    }

    static func load(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .default
        }
        return decoded
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try prettyJSON().write(to: url, atomically: true, encoding: .utf8)
    }

    func prettyJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func parse(json: String) throws -> AppConfig {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "KerioSplit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8"])
        }
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    mutating func sanitize() {
        vpnRoutes = Self.normalizeList(vpnRoutes)
        bypassRoutes = Self.normalizeList(bypassRoutes)
        options.customDns = Self.normalizeList(options.customDns)
    }

    private static func normalizeList(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, !seen.contains(s) else { continue }
            seen.insert(s)
            out.append(s)
        }
        return out
    }

    static func isValidHostOrCIDR(_ value: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "/")
        let ip = String(parts[0])
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts.count == 2 {
            guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        }
        return true
    }
}
