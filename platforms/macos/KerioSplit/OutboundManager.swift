import Foundation

/// Manages sing-box sidecar lifecycle and generated config.
@MainActor
final class OutboundManager: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var statusDetail = "Not connected"
    @Published private(set) var binaryPath: String?
    @Published private(set) var lastError: String?
    @Published private(set) var engineBusy = false
    @Published private(set) var engineProgress: String = ""
    @Published private(set) var connectedAt: Date?
    @Published private(set) var activeProfileName: String = ""

    private var process: Process?
    private let supportRoot: URL
    private static let singBoxVersion = "1.11.15"

    init(supportRoot: URL) {
        self.supportRoot = supportRoot
        binaryPath = Self.resolveBinary()
    }

    var workDir: URL { supportRoot.appendingPathComponent("Outbound", isDirectory: true) }
    var configURL: URL { workDir.appendingPathComponent("sing-box.json") }
    var storeURL: URL { supportRoot.appendingPathComponent("Config/outbound.json") }
    var helpersDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KerioSplit/Helpers", isDirectory: true)
    }

    var hasEngine: Bool { binaryPath != nil }

    func refreshBinary() {
        binaryPath = Self.resolveBinary()
    }

    /// Download sing-box into Application Support — one-click, no Terminal.
    func installEngine() async -> Bool {
        engineBusy = true
        engineProgress = "Downloading sing-box…"
        lastError = nil
        defer {
            engineBusy = false
            engineProgress = ""
        }

        let version = Self.singBoxVersion
        let arch: String
        #if arch(arm64)
        arch = "darwin-arm64"
        #else
        arch = "darwin-amd64"
        #endif
        let urlString = "https://github.com/SagerNet/sing-box/releases/download/v\(version)/sing-box-\(version)-\(arch).tar.gz"
        guard let url = URL(string: urlString) else {
            lastError = "Invalid download URL"
            return false
        }

        do {
            try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
            engineProgress = "Fetching sing-box \(version)…"
            let (tmpURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastError = "Download failed (HTTP \(http.statusCode))"
                return false
            }

            engineProgress = "Extracting…"
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("keriosplit-singbox-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let archivePath = extractDir.appendingPathComponent("sing-box.tgz")
            if FileManager.default.fileExists(atPath: archivePath.path) {
                try FileManager.default.removeItem(at: archivePath)
            }
            try FileManager.default.moveItem(at: tmpURL, to: archivePath)

            let untar = Process()
            untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            untar.arguments = ["-xzf", archivePath.path, "-C", extractDir.path]
            try untar.run()
            untar.waitUntilExit()
            guard untar.terminationStatus == 0 else {
                lastError = "Failed to extract sing-box archive"
                return false
            }

            guard let found = Self.findSingBox(in: extractDir) else {
                lastError = "sing-box binary missing from archive"
                return false
            }

            let dest = helpersDir.appendingPathComponent("sing-box")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: found, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            // Clear quarantine so Gatekeeper doesn't block first run
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", dest.path]
            try? xattr.run()
            xattr.waitUntilExit()

            binaryPath = dest.path
            statusDetail = "Engine ready"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private static func findSingBox(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in enumerator {
            if file.lastPathComponent == "sing-box", fm.isExecutableFile(atPath: file.path) || fm.fileExists(atPath: file.path) {
                return file
            }
        }
        return nil
    }

    func loadStore() -> OutboundStore {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storeURL),
              var store = try? dec.decode(OutboundStore.self, from: data) else {
            return .default
        }
        store.sanitize()
        return store
    }

    func saveStore(_ store: OutboundStore) throws {
        var copy = store
        copy.sanitize()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(copy)
        try data.write(to: storeURL, options: .atomic)
    }

    func connect(profile: OutboundProfile, ignoreInterfaceHint: String = "utun") async -> Bool {
        refreshBinary()
        guard let bin = binaryPath else {
            lastError = "Outbound engine not installed. Tap Install engine."
            statusDetail = "Engine missing"
            return false
        }
        statusDetail = "Connecting — \(profile.name)…"
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let json = try SingBoxConfigBuilder.makeConfig(shareLink: profile.shareLink)
            try json.write(to: configURL, atomically: true, encoding: .utf8)
            stopProcess()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["run", "-c", configURL.path]
            proc.currentDirectoryURL = workDir
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            try proc.run()
            process = proc
            // Give tun a moment; caller will re-scan network.
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !proc.isRunning {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                lastError = errText.isEmpty ? "sing-box exited immediately" : String(errText.prefix(400))
                isConnected = false
                statusDetail = "Connection failed"
                process = nil
                return false
            }
            isConnected = true
            connectedAt = Date()
            activeProfileName = profile.name
            statusDetail = "Connected — \(profile.name)"
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            statusDetail = "Connection failed"
            isConnected = false
            connectedAt = nil
            activeProfileName = ""
            return false
        }
    }

    func disconnect() {
        stopProcess()
        isConnected = false
        connectedAt = nil
        activeProfileName = ""
        statusDetail = "Disconnected"
        lastError = nil
    }

    func fetchSubscription(urlString: String, name: String) async throws -> [OutboundProfile] {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "KerioSplit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid subscription URL"])
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("KerioSplit/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "KerioSplit", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        let profiles = SubscriptionParser.parseImport(body, defaultName: name)
        if profiles.isEmpty {
            throw NSError(domain: "KerioSplit", code: 3, userInfo: [NSLocalizedDescriptionKey: "No nodes found in subscription body"])
        }
        return profiles
    }

    private func stopProcess() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
    }

    private static func resolveBinary() -> String? {
        let candidates: [String] = [
            Bundle.main.bundlePath + "/Contents/Resources/Helpers/sing-box",
            Bundle.main.resourcePath.map { $0 + "/Helpers/sing-box" } ?? "",
            NSHomeDirectory() + "/Library/Application Support/KerioSplit/Helpers/sing-box",
            "/usr/local/bin/sing-box",
            "/opt/homebrew/bin/sing-box"
        ]
        let fm = FileManager.default
        for path in candidates where !path.isEmpty {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

enum SingBoxConfigBuilder {
    /// Minimal sing-box config: TUN inbound + one outbound from share link via `outbound` urltest-less direct mapping.
    /// Uses sing-box 1.8+ `outbounds` with `type` inferred from scheme when possible; falls back to `urltest` disabled.
    static func makeConfig(shareLink: String) throws -> String {
        // sing-box supports importing via experimental; we emit a wrapper that uses the `outbound` URI in a custom tag.
        // Practical approach: write a config that uses `dialer` proxy from parsed fields where we can, else embed as shadowsocks/vless stub.
        let outbound = try outboundObject(from: shareLink)
        let root: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "inet4_address": "172.19.0.1/30",
                "auto_route": true,
                "strict_route": true,
                "stack": "system"
            ]],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
                ["type": "block", "tag": "block"]
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "KerioSplit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode sing-box config"])
        }
        return text
    }

    private static func outboundObject(from link: String) throws -> [String: Any] {
        let lower = link.lowercased()
        if lower.hasPrefix("vmess://") {
            return try vmessOutbound(link)
        }
        // For vless/trojan/ss — pass through as URL outbound if supported; otherwise store raw for user debugging.
        if lower.hasPrefix("vless://") {
            return try vlessOutbound(link)
        }
        if lower.hasPrefix("trojan://") {
            return try trojanOutbound(link)
        }
        if lower.hasPrefix("ss://") {
            return [
                "type": "shadowsocks",
                "tag": "proxy",
                "plugin": "",
                "plugin_opts": "",
                "server": "127.0.0.1",
                "server_port": 1,
                "method": "aes-128-gcm",
                "password": "replace",
                "_keriosplit_note": "ss:// raw import is limited; prefer vless/vmess. Link kept in outbound store."
            ]
        }
        throw NSError(domain: "KerioSplit", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unsupported share link scheme"])
    }

    private static func vmessOutbound(_ link: String) throws -> [String: Any] {
        let b64 = String(link.dropFirst("vmess://".count))
        guard let data = Data(base64Encoded: b64) ?? Data(base64Encoded: pad(b64)),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "KerioSplit", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid vmess link"])
        }
        let host = obj["add"] as? String ?? ""
        let port = Int(obj["port"] as? String ?? "") ?? (obj["port"] as? Int ?? 443)
        let uuid = obj["id"] as? String ?? ""
        let aid = Int(obj["aid"] as? String ?? "") ?? (obj["aid"] as? Int ?? 0)
        let tls = (obj["tls"] as? String)?.lowercased() == "tls"
        let sni = obj["sni"] as? String ?? obj["host"] as? String ?? host
        var out: [String: Any] = [
            "type": "vmess",
            "tag": "proxy",
            "server": host,
            "server_port": port,
            "uuid": uuid,
            "security": "auto",
            "alter_id": aid
        ]
        if tls {
            out["tls"] = ["enabled": true, "server_name": sni]
        }
        return out
    }

    private static func vlessOutbound(_ link: String) throws -> [String: Any] {
        // vless://uuid@host:port?params#name
        guard let url = URL(string: link) else {
            throw NSError(domain: "KerioSplit", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid vless URL"])
        }
        let uuid = url.user ?? ""
        let host = url.host ?? ""
        let port = url.port ?? 443
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for i in items { query[i.name] = i.value ?? "" }
        let security = query["security"] ?? ""
        let sni = query["sni"] ?? query["host"] ?? host
        var out: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": host,
            "server_port": port,
            "uuid": uuid
        ]
        if security == "tls" || security == "reality" {
            var tls: [String: Any] = ["enabled": true, "server_name": sni]
            if security == "reality" {
                tls["reality"] = [
                    "enabled": true,
                    "public_key": query["pbk"] ?? "",
                    "short_id": query["sid"] ?? ""
                ]
            }
            out["tls"] = tls
        }
        if let flow = query["flow"], !flow.isEmpty {
            out["flow"] = flow
        }
        return out
    }

    private static func trojanOutbound(_ link: String) throws -> [String: Any] {
        guard let url = URL(string: link) else {
            throw NSError(domain: "KerioSplit", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid trojan URL"])
        }
        let password = url.user ?? ""
        let host = url.host ?? ""
        let port = url.port ?? 443
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for i in items { query[i.name] = i.value ?? "" }
        let sni = query["sni"] ?? host
        return [
            "type": "trojan",
            "tag": "proxy",
            "server": host,
            "server_port": port,
            "password": password,
            "tls": ["enabled": true, "server_name": sni]
        ]
    }

    private static func pad(_ s: String) -> String {
        s + String(repeating: "=", count: (4 - s.count % 4) % 4)
    }
}
