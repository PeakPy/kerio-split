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
        var confirmBeforeDisconnect: Bool
        var launchAtLogin: Bool
        var showMenuBar: Bool
        var notifyOnChange: Bool

        static let `default` = Options(
            removeFullTunnel: true,
            restoreLanDefault: true,
            restoreLanDns: true,
            customDns: [],
            autoApplyOnLaunch: false,
            confirmBeforeDisconnect: true,
            launchAtLogin: false,
            showMenuBar: true,
            notifyOnChange: true
        )

        init(
            removeFullTunnel: Bool,
            restoreLanDefault: Bool,
            restoreLanDns: Bool,
            customDns: [String],
            autoApplyOnLaunch: Bool,
            confirmBeforeDisconnect: Bool,
            launchAtLogin: Bool,
            showMenuBar: Bool,
            notifyOnChange: Bool
        ) {
            self.removeFullTunnel = removeFullTunnel
            self.restoreLanDefault = restoreLanDefault
            self.restoreLanDns = restoreLanDns
            self.customDns = customDns
            self.autoApplyOnLaunch = autoApplyOnLaunch
            self.confirmBeforeDisconnect = confirmBeforeDisconnect
            self.launchAtLogin = launchAtLogin
            self.showMenuBar = showMenuBar
            self.notifyOnChange = notifyOnChange
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            removeFullTunnel = try c.decodeIfPresent(Bool.self, forKey: .removeFullTunnel) ?? true
            restoreLanDefault = try c.decodeIfPresent(Bool.self, forKey: .restoreLanDefault) ?? true
            restoreLanDns = try c.decodeIfPresent(Bool.self, forKey: .restoreLanDns) ?? true
            customDns = try c.decodeIfPresent([String].self, forKey: .customDns) ?? []
            autoApplyOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoApplyOnLaunch) ?? false
            confirmBeforeDisconnect = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDisconnect) ?? true
            launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
            showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
            notifyOnChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnChange) ?? true
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
