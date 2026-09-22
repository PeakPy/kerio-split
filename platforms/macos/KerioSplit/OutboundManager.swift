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
    private var usesPrivileged = false
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

    func connect(
        profile: OutboundProfile,
        bindInterface: String = "",
        excludeInterfaces: [String] = [],
        kerioCIDRs: [String] = []
    ) async -> Bool {
        refreshBinary()
        guard let bin = binaryPath else {
            lastError = "Outbound engine not installed. Tap Install engine."
            statusDetail = "Engine missing"
            return false
        }
        statusDetail = "Connecting — \(profile.name)…"
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let json = try SingBoxConfigBuilder.makeConfig(
                shareLink: profile.shareLink,
                bindInterface: bindInterface,
                excludeInterfaces: excludeInterfaces,
                kerioCIDRs: kerioCIDRs
            )
            try json.write(to: configURL, atomically: true, encoding: .utf8)
            await stopAll()

            let helperReady = await Task.detached(priority: .userInitiated) {
                HelperService.canRunPasswordless()
            }.value

            if helperReady {
                let cfgPath = configURL.path
                let result = await Task.detached(priority: .userInitiated) {
                    HelperService.runCtl(["outbound-start", bin, cfgPath])
                }.value
                if result.ok {
                    // Confirm TUN actually came up — otherwise UI shows Connected while dead.
                    let tunUp = await Self.waitForOutboundTun(timeoutSeconds: 2.5)
                    if !tunUp {
                        _ = await Task.detached(priority: .userInitiated) {
                            HelperService.runCtl(["outbound-stop"])
                        }.value
                        lastError = "Outbound TUN did not appear (172.19.0.1). Engine started then exited — check Activity / sing-box.log"
                        isConnected = false
                        statusDetail = "Connection failed"
                        usesPrivileged = false
                        return false
                    }
                    usesPrivileged = true
                    process = nil
                    isConnected = true
                    connectedAt = Date()
                    activeProfileName = profile.name
                    statusDetail = "Connected — \(profile.name)"
                    lastError = nil
                    return true
                }
                lastError = Self.sanitizeEngineError(result.text.isEmpty ? "Privileged outbound start failed" : result.text)
                isConnected = false
                statusDetail = "Connection failed"
                usesPrivileged = false
                return false
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["run", "-c", configURL.path]
            proc.currentDirectoryURL = workDir
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            try proc.run()
            process = proc
            usesPrivileged = false
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !proc.isRunning {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                var cleaned = Self.sanitizeEngineError(errText)
                if cleaned.isEmpty { cleaned = "sing-box exited immediately" }
                if cleaned.lowercased().contains("permission") || cleaned.lowercased().contains("operation not permitted") {
                    cleaned += " — install the route helper so outbound can create a TUN as root."
                } else if !HelperService.filesPresent {
                    cleaned += " — if this keeps failing, Install route helper (TUN needs admin)."
                }
                lastError = cleaned
                isConnected = false
                statusDetail = "Connection failed"
                process = nil
                return false
            }
            let tunUp = await Self.waitForOutboundTun(timeoutSeconds: 2.0)
            if !tunUp {
                stopProcess()
                lastError = "Outbound TUN did not appear (172.19.0.1)"
                isConnected = false
                statusDetail = "Connection failed"
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
            usesPrivileged = false
            return false
        }
    }

    func disconnect() {
        stopProcess()
        let needPrivilegedStop = usesPrivileged || FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("sing-box.pid").path
        )
        if needPrivilegedStop && HelperService.filesPresent {
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = HelperService.runCtl(["outbound-stop"])
                group.leave()
            }
            _ = group.wait(timeout: .now() + 8)
        }
        isConnected = false
        connectedAt = nil
        activeProfileName = ""
        statusDetail = "Disconnected"
        lastError = nil
        usesPrivileged = false
    }

    private func stopAll() async {
        stopProcess()
        if HelperService.filesPresent {
            await Task.detached(priority: .userInitiated) {
                _ = HelperService.runCtl(["outbound-stop"])
            }.value
        }
        usesPrivileged = false
    }

    static func sanitizeEngineError(_ raw: String) -> String {
        var s = raw.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(of: "\r", with: "")
        let lines = s
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let useful = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error")
                || lower.contains("failed")
                || lower.contains("permission")
                || lower.contains("denied")
                || lower.contains("outbound=")
                || lower.hasPrefix("FATAL")
                || lower.contains("tun")
        }
        let pick = (useful.last ?? lines.last ?? s).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(pick.prefix(320))
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

    /// True while our sing-box process (or privileged root pid) is still alive.
    func isEngineAlive() -> Bool {
        if let proc = process { return proc.isRunning }

        let pidURL = workDir.appendingPathComponent("sing-box.pid")
        if let text = try? String(contentsOf: pidURL, encoding: .utf8) {
            let pid = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int32(pid), value > 1 {
                let rc = kill(value, 0)
                if rc == 0 { return true }
                // Privileged outbound-start runs as root — user kill(0) gets EPERM
                // while the process is still alive. That must NOT look like "dead".
                if errno == EPERM { return true }
            }
        }
        // Fallback: any sing-box we started with our config path
        return HelperService.runProcess(
            "/usr/bin/pgrep",
            ["-f", "sing-box run -c \(configURL.path)"],
            timeoutSeconds: 2
        ).ok
    }

    private static func waitForOutboundTun(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if findOutboundTunIface() != nil { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return findOutboundTunIface() != nil
    }

    static func findOutboundTunIface() -> String? {
        let result = HelperService.runProcess("/sbin/ifconfig", ["-a"], timeoutSeconds: 2)
        guard result.ok else { return nil }
        var current: String?
        for raw in result.text.split(separator: "\n") {
            let line = String(raw)
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon])
                if name.hasPrefix("utun") {
                    current = name
                } else if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                    current = nil
                }
            }
            guard let iface = current else { continue }
            if line.contains("inet 172.19.0.") {
                return iface
            }
        }
        return nil
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
    /// Dual-VPN safe: dial VLESS on LAN only (never via Kerio). Kerio private CIDRs stay on Kerio.
    static func makeConfig(
        shareLink: String,
        bindInterface: String = "",
        excludeInterfaces: [String] = [],
        kerioCIDRs: [String] = []
    ) throws -> String {
        var outbound = try outboundObject(from: shareLink)
        let lan = Self.physicalLAN(bindInterface)
        outbound["tcp_fast_open"] = true
        outbound["udp_fragment"] = true
        outbound["tcp_multi_path"] = true
        // CRITICAL: proxy dial must leave via Wi-Fi/Ethernet — never Kerio utun.
        if !lan.isEmpty {
            outbound["bind_interface"] = lan
        }

        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30"],
            // Dual-VPN: high MTU under Kerio causes PMTU blackholes / slow TCP. Karing-class clients stay near Ethernet MTU.
            "mtu": 1400,
            "auto_route": true,
            // Keep false when Kerio may be present so we don't steal corporate routes.
            "strict_route": false,
            "stack": "mixed"
        ]
        let excludes = excludeInterfaces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != lan && !$0.hasPrefix("en") }
        if !excludes.isEmpty {
            tunInbound["exclude_interface"] = excludes
        }
        // Never let sing-box auto_route claim Kerio corporate CIDRs.
        let excludeAddrs = kerioCIDRs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !excludeAddrs.isEmpty {
            tunInbound["route_exclude_address"] = excludeAddrs
        }

        // Order matters: FakeIP (198.18/15) is "private-looking" but MUST go to proxy.
        // Real LAN / Kerio RFC1918 stays on system table (Kerio utun wins for corporate).
        var route: [String: Any] = [
            "rules": [
                ["action": "sniff", "timeout": "50ms"],
                ["protocol": "dns", "action": "hijack-dns"],
                ["ip_cidr": ["198.18.0.0/15"], "outbound": "proxy"],
                [
                        "ip_cidr": [
                        "10.0.0.0/8",
                        // Skip 172.19.0.0/30 (our TUN) — keep rest of 172.16/12 for Kerio/LAN.
                        "172.16.0.0/12",
                        "192.168.0.0/16",
                        "127.0.0.0/8",
                        "169.254.0.0/16"
                    ],
                    "outbound": "direct"
                ]
            ],
            "final": "proxy"
        ]
        if !lan.isEmpty {
            route["default_interface"] = lan
            route["auto_detect_interface"] = false
        } else {
            route["auto_detect_interface"] = true
        }

        // Karing FakeIP model: intercept DNS → fake IP locally; real resolve happens on the proxy node.
        // Do NOT detour residual DNS through the proxy (double-hop DNS kills throughput).
        let root: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "dns": [
                "servers": [
                    ["tag": "remote", "address": "8.8.8.8", "detour": "direct"],
                    ["tag": "local", "address": "local", "detour": "direct"],
                    ["tag": "fakeip", "address": "fakeip"]
                ],
                "rules": [
                    // Resolve proxy server hostname on LAN DNS — not through Kerio/proxy loop.
                    ["outbound": "any", "server": "local"],
                    ["query_type": ["A", "AAAA"], "server": "fakeip"]
                ],
                "fakeip": [
                    "enabled": true,
                    "inet4_range": "198.18.0.0/15"
                ],
                "final": "remote",
                "strategy": "ipv4_only",
                "independent_cache": true
            ],
            "inbounds": [tunInbound],
            "outbounds": [
                outbound,
                // direct also binds LAN so "private → direct" never exits via Kerio by mistake
                lan.isEmpty
                    ? ["type": "direct", "tag": "direct"]
                    : ["type": "direct", "tag": "direct", "bind_interface": lan],
                ["type": "block", "tag": "block"]
            ],
            "route": route
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "KerioSplit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode sing-box config"])
        }
        return text
    }

    /// Only physical Ethernet/Wi-Fi — never a utun (Kerio or outbound).
    private static func physicalLAN(_ candidate: String) -> String {
        let s = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("en") { return s }
        return ""
    }

    private static func outboundObject(from link: String) throws -> [String: Any] {
        let lower = link.lowercased()
        if lower.hasPrefix("vmess://") { return try vmessOutbound(link) }
        if lower.hasPrefix("vless://") { return try vlessOutbound(link) }
        if lower.hasPrefix("trojan://") { return try trojanOutbound(link) }
        if lower.hasPrefix("ss://") {
            throw NSError(
                domain: "KerioSplit",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Shadowsocks links are not supported yet — use VLESS / VMess / Trojan"]
            )
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
            "alter_id": aid,
            "packet_encoding": "xudp"
        ]
        if tls {
            var tlsObj: [String: Any] = ["enabled": true, "server_name": sni]
            if let fp = obj["fp"] as? String, !fp.isEmpty {
                tlsObj["utls"] = ["enabled": true, "fingerprint": fp]
            }
            out["tls"] = tlsObj
        }
        if let net = (obj["net"] as? String)?.lowercased(), net == "ws" {
            var path = obj["path"] as? String ?? ""
            var early: Int?
            let stripped = stripEarlyData(fromPath: path)
            path = stripped.path
            early = stripped.early
            if let ed = obj["ed"] as? Int { early = ed }
            if let ed = Int(obj["ed"] as? String ?? "") { early = ed }
            var transport: [String: Any] = ["type": "ws"]
            if !path.isEmpty { transport["path"] = path }
            if let hostHeader = obj["host"] as? String, !hostHeader.isEmpty {
                transport["headers"] = ["Host": hostHeader]
            }
            if let early, early > 0 {
                transport["max_early_data"] = early
                transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            out["transport"] = transport
        }
        return out
    }

    private static func vlessOutbound(_ link: String) throws -> [String: Any] {
        guard let parsed = ShareLinkEndpoint.parse(link), parsed.scheme == "vless" else {
            throw NSError(domain: "KerioSplit", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid vless URL"])
        }
        let query = parsed.query
        let security = (query["security"] ?? "").lowercased()
        let sni = query["sni"] ?? query["host"] ?? parsed.host
        let packetEncoding = (query["packetEncoding"] ?? query["packet_encoding"] ?? "xudp")
        var out: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": parsed.host,
            "server_port": parsed.port,
            "uuid": parsed.userInfo,
            "packet_encoding": packetEncoding.isEmpty ? "xudp" : packetEncoding
        ]
        if security == "tls" || security == "reality" {
            var tls: [String: Any] = [
                "enabled": true,
                "server_name": sni
            ]
            let fp = query["fp"] ?? "chrome"
            if !fp.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": fp]
            }
            if security == "reality" {
                tls["reality"] = [
                    "enabled": true,
                    "public_key": query["pbk"] ?? "",
                    "short_id": query["sid"] ?? ""
                ]
            }
            out["tls"] = tls
        }
        let flow = query["flow"] ?? ""
        if !flow.isEmpty {
            out["flow"] = flow
        }
        if let transport = transportObject(from: query) {
            out["transport"] = transport
        }
        let transportType = (query["type"] ?? query["net"] ?? "tcp").lowercased()
        // Mux only when the link explicitly asks (Karing: requires server support; wrong mux tanks speed).
        let muxFlag = (query["mux"] ?? query["multiplex"] ?? "").lowercased()
        let wantsMux = muxFlag == "1" || muxFlag == "true" || muxFlag == "yes"
        if wantsMux, flow.isEmpty, transportType == "ws" || transportType == "websocket" || transportType == "grpc" {
            out["multiplex"] = [
                "enabled": true,
                "protocol": "h2mux",
                "max_connections": 4,
                "min_streams": 4,
                "padding": false
            ]
        }
        return out
    }

    private static func trojanOutbound(_ link: String) throws -> [String: Any] {
        guard let parsed = ShareLinkEndpoint.parse(link), parsed.scheme == "trojan" else {
            throw NSError(domain: "KerioSplit", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid trojan URL"])
        }
        let query = parsed.query
        let sni = query["sni"] ?? query["host"] ?? parsed.host
        var out: [String: Any] = [
            "type": "trojan",
            "tag": "proxy",
            "server": parsed.host,
            "server_port": parsed.port,
            "password": parsed.userInfo,
            "tls": [
                "enabled": true,
                "server_name": sni,
                "utls": ["enabled": true, "fingerprint": query["fp"] ?? "chrome"]
            ]
        ]
        if let transport = transportObject(from: query) {
            out["transport"] = transport
        }
        return out
    }

    private static func transportObject(from query: [String: String]) -> [String: Any]? {
        let type = (query["type"] ?? query["net"] ?? "tcp").lowercased()
        switch type {
        case "ws", "websocket":
            var path = (query["path"] ?? "").removingPercentEncoding ?? (query["path"] ?? "")
            var early = Int(query["ed"] ?? "")
            let stripped = stripEarlyData(fromPath: path)
            path = stripped.path
            if early == nil { early = stripped.early }
            var t: [String: Any] = ["type": "ws"]
            if !path.isEmpty { t["path"] = path }
            if let host = query["host"], !host.isEmpty {
                t["headers"] = ["Host": host]
            }
            // ed=2560 must be max_early_data — never left in the path (Karing does this).
            if let early, early > 0 {
                t["max_early_data"] = early
                t["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            return t
        case "grpc":
            var t: [String: Any] = ["type": "grpc"]
            if let service = query["serviceName"] ?? query["servicename"], !service.isEmpty {
                t["service_name"] = service
            }
            return t
        case "http", "h2":
            var t: [String: Any] = ["type": "http"]
            if let path = query["path"], !path.isEmpty { t["path"] = path }
            if let host = query["host"], !host.isEmpty { t["host"] = [host] }
            return t
        default:
            return nil
        }
    }

    /// `/path?ed=2560` → (`/path`, 2560)
    private static func stripEarlyData(fromPath path: String) -> (path: String, early: Int?) {
        guard let q = path.firstIndex(of: "?") else { return (path, nil) }
        let base = String(path[..<q])
        let query = String(path[path.index(after: q)...])
        var early: Int?
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, kv[0] == "ed", let v = Int(kv[1]), v > 0 else { continue }
            early = v
        }
        return (base, early)
    }

    private static func pad(_ s: String) -> String {
        s + String(repeating: "=", count: (4 - s.count % 4) % 4)
    }
}
