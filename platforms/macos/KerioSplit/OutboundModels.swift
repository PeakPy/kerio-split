import Foundation

enum OutboundMode: String, Codable, CaseIterable, Identifiable {
    case off
    case builtIn
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .builtIn: return "Built-in"
        case .external: return "External"
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return "Only Kerio split — no second VPN."
        case .builtIn:
            return "Connect a vless / vmess / trojan profile inside Kerio Split."
        case .external:
            return "Use V2Box, Clash, Karing… We guard Kerio routes around it."
        }
    }
}

extension OutboundProfile {
    var protocolLabel: String {
        let lower = shareLink.lowercased()
        if lower.hasPrefix("vless://") { return "VLESS" }
        if lower.hasPrefix("vmess://") { return "VMess" }
        if lower.hasPrefix("trojan://") { return "Trojan" }
        if lower.hasPrefix("ss://") { return "SS" }
        if lower.hasPrefix("hysteria2://") || lower.hasPrefix("hy2://") { return "Hy2" }
        if lower.hasPrefix("tuic://") { return "TUIC" }
        return "VPN"
    }
}

struct OutboundProfile: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var shareLink: String
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, shareLink: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.shareLink = shareLink
        self.createdAt = createdAt
    }
}

struct OutboundSubscription: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var lastFetchedAt: Date?
    var profileIds: [String]

    init(id: String = UUID().uuidString, name: String, url: String, lastFetchedAt: Date? = nil, profileIds: [String] = []) {
        self.id = id
        self.name = name
        self.url = url
        self.lastFetchedAt = lastFetchedAt
        self.profileIds = profileIds
    }
}

struct OutboundStore: Codable, Equatable {
    var profiles: [OutboundProfile]
    var subscriptions: [OutboundSubscription]
    var activeProfileId: String?

    static let `default` = OutboundStore(profiles: [], subscriptions: [], activeProfileId: nil)

    mutating func sanitize() {
        profiles = profiles.filter { !$0.shareLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        subscriptions = subscriptions.filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let id = activeProfileId, !profiles.contains(where: { $0.id == id }) {
            activeProfileId = profiles.first?.id
        }
    }
}

enum SubscriptionParser {
    /// Parse a single share link or a newline/base64 subscription body into profiles.
    static func parseImport(_ raw: String, defaultName: String = "Node") -> [OutboundProfile] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return []
        }

        // Try base64 subscription blob
        if !trimmed.contains("://"), let decoded = decodeBase64(trimmed) {
            return parseLines(decoded, defaultName: defaultName)
        }

        if trimmed.contains("://") && trimmed.contains("\n") == false {
            return [profile(from: trimmed, fallbackName: defaultName)].compactMap { $0 }
        }

        return parseLines(trimmed, defaultName: defaultName)
    }

    private static func parseLines(_ text: String, defaultName: String) -> [OutboundProfile] {
        var out: [OutboundProfile] = []
        for (idx, line) in text.split(whereSeparator: \.isNewline).map(String.init).enumerated() {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, !s.hasPrefix("#") else { continue }
            if let p = profile(from: s, fallbackName: "\(defaultName) \(idx + 1)") {
                out.append(p)
            }
        }
        return out
    }

    private static func profile(from link: String, fallbackName: String) -> OutboundProfile? {
        let lower = link.lowercased()
        guard lower.hasPrefix("vless://")
            || lower.hasPrefix("vmess://")
            || lower.hasPrefix("trojan://")
            || lower.hasPrefix("ss://")
            || lower.hasPrefix("hysteria2://")
            || lower.hasPrefix("hy2://")
            || lower.hasPrefix("tuic://")
            || lower.hasPrefix("wireguard://")
        else { return nil }

        var name = fallbackName
        if let hash = link.split(separator: "#").last, link.contains("#") {
            let decoded = hash.removingPercentEncoding ?? String(hash)
            if !decoded.isEmpty { name = decoded }
        } else if lower.hasPrefix("vmess://"), let jsonName = vmessName(link) {
            name = jsonName
        }
        return OutboundProfile(name: name, shareLink: link)
    }

    private static func vmessName(_ link: String) -> String? {
        let b64 = link.replacingOccurrences(of: "vmess://", with: "", options: .caseInsensitive)
        guard let data = Data(base64Encoded: b64) ?? Data(base64Encoded: padBase64(b64)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ps = obj["ps"] as? String, !ps.isEmpty else { return nil }
        return ps
    }

    private static func decodeBase64(_ s: String) -> String? {
        let cleaned = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: cleaned) ?? Data(base64Encoded: padBase64(cleaned)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func padBase64(_ s: String) -> String {
        let pad = (4 - s.count % 4) % 4
        return s + String(repeating: "=", count: pad)
    }
}
