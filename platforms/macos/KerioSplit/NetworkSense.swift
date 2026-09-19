import Foundation

/// Snapshot of what the Mac's routing table and interfaces look like right now.
struct NetworkSnapshot: Equatable {
    var lanGateway: String = ""
    var lanInterface: String = ""
    var defaultGateway: String = ""
    var defaultInterface: String = ""
    var kerioInterface: String = ""
    var kerioGateway: String = ""
    var kerioTunnelAddress: String = ""
    var fullTunnelHijack: Bool = false
    var secondaryTuns: [String] = []
    var allUtuns: [String] = []
    var dnsServers: [String] = []
    var managedRoutesMissing: [String] = []
    var managedRoutesPresent: [String] = []
    var conflict: Bool = false
    var conflictDetail: String = ""
    var scannedAt: Date = Date()

    /// Official Kerio NE session reported Connected by scutil.
    var kerioSessionConnected: Bool = false
    var kerioSessionLabel: String = ""
    /// kvpncsvc daemon is running.
    var kerioDaemonRunning: Bool = false
    /// How we decided the tunnel is up (for diagnostics).
    var tunnelEvidence: [String] = []
    /// All system VPN / NE sessions from `scutil --nc list` (Kerio, Karing, Clash, …).
    var vpnSessions: [VPNSession] = []

    var hasKerioTunnel: Bool {
        // Live evidence only — a stale saved gateway must NOT count as "up".
        kerioSessionConnected
            || fullTunnelHijack
            || !kerioInterface.isEmpty
            || !managedRoutesPresent.isEmpty
    }

    var hasExternalOutbound: Bool {
        !secondaryTuns.isEmpty
    }

    var defaultOnLAN: Bool {
        defaultInterface.hasPrefix("en")
    }

    var connectedVPNCount: Int {
        vpnSessions.filter(\.isConnected).count
    }
}

/// One row from `scutil --nc list` — any system VPN / Network Extension.
struct VPNSession: Identifiable, Equatable, Hashable {
    enum Kind: String, Equatable {
        case kerio
        case outbound
        case system
        case unknown
    }

    var id: String
    var name: String
    var provider: String
    var isConnected: Bool
    var kind: Kind
    var detail: String

    var shortProvider: String {
        if provider.contains("kerio") { return "Kerio" }
        if provider.contains("karing") { return "Karing" }
        if provider.contains("clash") { return "Clash" }
        if provider.contains("sing") || provider.contains("sfovpn") { return "sing-box" }
        if provider.contains("wireguard") { return "WireGuard" }
        if provider.contains("openvpn") { return "OpenVPN" }
        let last = provider.split(separator: ".").last.map(String.init) ?? provider
        return last.isEmpty ? "VPN" : last
    }
}

struct DiagnosticItem: Identifiable, Equatable {
    enum Status: String, Equatable {
        case ok
        case warn
        case fail
        case info
    }

    let id: String
    let title: String
    let status: Status
    let detail: String
}

struct DiagnosticReport: Equatable {
    var items: [DiagnosticItem] = []
    var summary: String = ""
    var suggestedFix: String = ""
    var generatedAt: Date = Date()

    var plainText: String {
        var lines: [String] = ["Kerio Split diagnostics — \(generatedAt)"]
        lines.append(summary)
        if !suggestedFix.isEmpty {
            lines.append("Suggested: \(suggestedFix)")
        }
        lines.append("")
        for item in items {
            lines.append("[\(item.status.rawValue.uppercased())] \(item.title): \(item.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

enum NetworkSense {
    /// Build a snapshot using pin/ignore rules from config.
    static func scan(
        pinnedInterface: String,
        pinnedGateway: String,
        ignoreInterfaces: [String],
        vpnRoutes: [String],
        splitActive: Bool
    ) -> NetworkSnapshot {
        let ignore = Set(ignoreInterfaces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

        // Parallel probes — sequential netstat/ifconfig/scutil made every refresh feel laggy.
        final class ProbeBox: @unchecked Sendable {
            var routes = ""
            var ifconfig = ""
            var ncList = ""
            var daemon = false
        }
        let box = ProbeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.routes = HelperService.runProcess("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeoutSeconds: 2).text
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.ifconfig = HelperService.runProcess("/sbin/ifconfig", ["-a"], timeoutSeconds: 2).text
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.ncList = HelperService.runProcess("/usr/sbin/scutil", ["--nc", "list"], timeoutSeconds: 2).text
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.daemon = HelperService.runProcess("/usr/bin/pgrep", ["-x", "kvpncsvc"], timeoutSeconds: 1).ok
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.5)

        let routes = box.routes
        let ifconfig = box.ifconfig
        let ncList = box.ncList

        var snap = NetworkSnapshot()
        snap.scannedAt = Date()
        snap.fullTunnelHijack = routes.contains("0/1") || routes.contains("128.0/1")
        snap.kerioDaemonRunning = box.daemon

        let session = parseKerioSession(ncList)
        snap.kerioSessionConnected = session.connected
        snap.kerioSessionLabel = session.label
        snap.vpnSessions = parseAllVPNSessions(ncList)
        if session.connected {
            snap.tunnelEvidence.append("scutil: Kerio session Connected (\(session.label))")
        }

        parseDefaults(routes: routes, into: &snap)
        let utuns = ipv4TunnelIfaces(from: ifconfig)
        snap.allUtuns = utuns.sorted()

        let pinIf = pinnedInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinGw = pinnedGateway.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Strongest: routing table maps configured VPN CIDRs → iface/gw
        if let hit = findIfaceForVPNRoutes(vpnRoutes, routes: routes, ignore: ignore) {
            snap.kerioInterface = hit.iface
            snap.kerioGateway = hit.gateway
            snap.managedRoutesPresent = hit.matched
            snap.tunnelEvidence.append("routes: \(hit.matched.joined(separator: ", ")) → \(hit.iface) via \(hit.gateway)")
        }

        // 2) Pin (only if still up)
        if snap.kerioInterface.isEmpty, !pinIf.isEmpty, interfaceHasIPv4(pinIf, ifconfig: ifconfig) {
            snap.kerioInterface = pinIf
            snap.tunnelEvidence.append("pin: \(pinIf)")
        }

        // 3) Full-tunnel hijack iface
        if snap.kerioInterface.isEmpty,
           let fromHijack = interfaceForPrefix("0/1", routes: routes),
           !ignore.contains(fromHijack) {
            snap.kerioInterface = fromHijack
            snap.tunnelEvidence.append("hijack 0/1 on \(fromHijack)")
        }

        // 4) Session connected + pick best utun (prefer non-ignored with IPv4)
        if snap.kerioInterface.isEmpty, session.connected {
            if let best = utuns.first(where: { !ignore.contains($0) }) {
                snap.kerioInterface = best
                snap.tunnelEvidence.append("session Connected → iface \(best)")
            } else if let any = utuns.first {
                // All tuns ignored by mistake — still bind Kerio session to a tun
                snap.kerioInterface = any
                snap.tunnelEvidence.append("session Connected → iface \(any) (was ignored)")
            }
        }

        // Do NOT treat "daemon running" alone as a tunnel — kvpncsvc stays up while Disconnected.

        // Gateway: prefer live route hit, then pin only when iface is actually up
        if snap.kerioGateway.isEmpty, !pinGw.isEmpty, !snap.kerioInterface.isEmpty {
            snap.kerioGateway = pinGw
        } else if snap.kerioGateway.isEmpty, let gw = gatewayForPrefix("0/1", routes: routes) {
            snap.kerioGateway = gw
        } else if snap.kerioGateway.isEmpty, !snap.kerioInterface.isEmpty {
            snap.kerioGateway = gatewayFromIface(snap.kerioInterface, ifconfig: ifconfig, routes: routes)
        }

        if !snap.kerioInterface.isEmpty {
            snap.kerioTunnelAddress = ipv4OnIface(snap.kerioInterface, ifconfig: ifconfig)
        }

        if !snap.kerioInterface.isEmpty {
            snap.secondaryTuns = utuns.filter { $0 != snap.kerioInterface }
        } else {
            snap.secondaryTuns = utuns.filter { ignore.contains($0) }
        }

        snap.dnsServers = currentDNS()

        let classified = classifyVPNRoutes(vpnRoutes, routes: routes)
        if snap.managedRoutesPresent.isEmpty {
            snap.managedRoutesPresent = classified.present
        }
        if splitActive {
            snap.managedRoutesMissing = classified.missing
        }

        if splitActive, !snap.hasKerioTunnel {
            snap.conflict = true
            snap.conflictDetail = "Split is ON but no Kerio tunnel/session is visible."
        } else if splitActive, !snap.managedRoutesMissing.isEmpty {
            snap.conflict = true
            snap.conflictDetail = "\(snap.managedRoutesMissing.count) VPN route(s) missing from the table."
        }
        // Default on another utun (Clash/Karing/…) while Kerio CIDRs are present is
        // healthy dual-VPN coexistence — not a conflict.

        return snap
    }

    static func diagnose(
        helperReady: Bool,
        canClickKerio: Bool,
        isActive: Bool,
        snapshot: NetworkSnapshot,
        vpnRoutes: [String],
        connectivity: ConnectivityReport,
        kerioInstalled: Bool
    ) -> DiagnosticReport {
        var items: [DiagnosticItem] = []

        items.append(DiagnosticItem(
            id: "helper",
            title: "Route helper",
            status: helperReady ? .ok : .fail,
            detail: helperReady ? "Passwordless helper ready" : "Not installed — Connect All cannot apply routes"
        ))

        items.append(DiagnosticItem(
            id: "client",
            title: "Kerio client",
            status: kerioInstalled ? .ok : .fail,
            detail: kerioInstalled ? "Official Kerio VPN Client is installed" : "Kerio Control VPN Client not found"
        ))

        items.append(DiagnosticItem(
            id: "daemon",
            title: "Kerio daemon (kvpncsvc)",
            status: snapshot.kerioDaemonRunning ? .ok : .warn,
            detail: snapshot.kerioDaemonRunning ? "Running" : "Not running — open Kerio and Connect"
        ))

        items.append(DiagnosticItem(
            id: "session",
            title: "Kerio session (scutil)",
            status: snapshot.kerioSessionConnected ? .ok : .fail,
            detail: snapshot.kerioSessionConnected
                ? "Connected — \(snapshot.kerioSessionLabel.isEmpty ? "Kerio VPN" : snapshot.kerioSessionLabel)"
                : "Disconnected"
        ))

        items.append(DiagnosticItem(
            id: "tunnel",
            title: "Tunnel interface",
            status: snapshot.kerioInterface.isEmpty ? .fail : .ok,
            detail: snapshot.kerioInterface.isEmpty
                ? "No Kerio utun/kvnet with IPv4"
                : "\(snapshot.kerioInterface) addr \(snapshot.kerioTunnelAddress.isEmpty ? "?" : snapshot.kerioTunnelAddress) gw \(snapshot.kerioGateway.isEmpty ? "?" : snapshot.kerioGateway)"
        ))

        items.append(DiagnosticItem(
            id: "hijack",
            title: "Full-tunnel hijack (0/1)",
            status: snapshot.fullTunnelHijack ? .warn : .ok,
            detail: snapshot.fullTunnelHijack ? "Present — Apply split to restore LAN default" : "Not present"
        ))

        let routeStatus: DiagnosticItem.Status
        let routeDetail: String
        if vpnRoutes.isEmpty {
            routeStatus = .warn
            routeDetail = "No VPN routes configured"
        } else if snapshot.managedRoutesPresent.count >= vpnRoutes.count || snapshot.managedRoutesMissing.isEmpty && snapshot.hasKerioTunnel && isActive {
            routeStatus = snapshot.managedRoutesMissing.isEmpty ? .ok : .warn
            routeDetail = "Present \(snapshot.managedRoutesPresent.count)/\(vpnRoutes.count)"
                + (snapshot.managedRoutesMissing.isEmpty ? "" : " · missing \(snapshot.managedRoutesMissing.joined(separator: ", "))")
        } else if snapshot.hasKerioTunnel {
            routeStatus = isActive ? .warn : .info
            routeDetail = isActive
                ? "Tunnel up but managed routes incomplete"
                : "Tunnel up — split not applied yet (\(vpnRoutes.count) configured)"
        } else {
            routeStatus = .info
            routeDetail = "\(vpnRoutes.count) configured — waiting for Kerio Connect"
        }
        items.append(DiagnosticItem(id: "routes", title: "VPN routes", status: routeStatus, detail: routeDetail))

        items.append(DiagnosticItem(
            id: "split",
            title: "Split state",
            status: isActive ? .ok : .info,
            detail: isActive ? "Split ON" : "Split OFF"
        ))

        items.append(DiagnosticItem(
            id: "ax",
            title: "Accessibility",
            status: canClickKerio ? .ok : .warn,
            detail: canClickKerio ? "Can click Kerio menu" : "Off — Connect All cannot click Kerio"
        ))

        let defaultOnSecondary = !snapshot.defaultOnLAN
            && snapshot.defaultInterface.hasPrefix("utun")
            && snapshot.secondaryTuns.contains(snapshot.defaultInterface)
        let dualVPNHealthy = isActive
            && snapshot.hasKerioTunnel
            && snapshot.managedRoutesMissing.isEmpty
            && !vpnRoutes.isEmpty
            && (defaultOnSecondary || snapshot.hasExternalOutbound)

        let defaultStatus: DiagnosticItem.Status
        let defaultDetail: String
        if snapshot.defaultOnLAN {
            defaultStatus = .ok
            defaultDetail = "\(snapshot.defaultInterface) via \(snapshot.defaultGateway) (LAN)"
        } else if dualVPNHealthy || defaultOnSecondary {
            defaultStatus = .ok
            defaultDetail = "\(snapshot.defaultInterface) via \(snapshot.defaultGateway.isEmpty ? "link" : snapshot.defaultGateway) — internet via external VPN; Kerio CIDRs stay on \(snapshot.kerioInterface.isEmpty ? "Kerio" : snapshot.kerioInterface)"
        } else {
            defaultStatus = .warn
            defaultDetail = "\(snapshot.defaultInterface.isEmpty ? "?" : snapshot.defaultInterface) via \(snapshot.defaultGateway.isEmpty ? "?" : snapshot.defaultGateway)"
        }
        items.append(DiagnosticItem(
            id: "default",
            title: "Default route",
            status: defaultStatus,
            detail: defaultDetail
        ))

        if !snapshot.secondaryTuns.isEmpty {
            items.append(DiagnosticItem(
                id: "secondary",
                title: "Other tunnels",
                status: dualVPNHealthy ? .ok : .info,
                detail: dualVPNHealthy
                    ? "\(snapshot.secondaryTuns.joined(separator: ", ")) — dual-VPN coexistence"
                    : snapshot.secondaryTuns.joined(separator: ", ")
            ))
        }

        if !connectivity.detail.isEmpty {
            items.append(DiagnosticItem(
                id: "ping",
                title: "Connectivity",
                status: connectivity.internetOK || connectivity.lanOK ? .ok : .warn,
                detail: connectivity.detail
            ))
        }

        if !snapshot.tunnelEvidence.isEmpty {
            items.append(DiagnosticItem(
                id: "evidence",
                title: "Tunnel evidence",
                status: .info,
                detail: snapshot.tunnelEvidence.joined(separator: " · ")
            ))
        }

        if snapshot.conflict {
            items.append(DiagnosticItem(
                id: "conflict",
                title: "Conflict",
                status: .fail,
                detail: snapshot.conflictDetail
            ))
        }

        var report = DiagnosticReport(items: items, generatedAt: Date())

        if !kerioInstalled {
            report.summary = "Kerio client missing"
            report.suggestedFix = "Install Kerio Control VPN Client, then reopen Kerio Split."
        } else if !snapshot.kerioSessionConnected && snapshot.kerioInterface.isEmpty {
            report.summary = "Kerio is not connected"
            report.suggestedFix = canClickKerio
                ? "Tap Connect All, or Connect from the Kerio menu bar icon."
                : "Connect in Kerio manually, or enable Accessibility and tap Connect All."
        } else if snapshot.hasKerioTunnel && !isActive {
            report.summary = "Kerio is up — split is off"
            report.suggestedFix = helperReady ? "Tap Connect All (or Apply) to pin only your VPN routes." : "Install the route helper, then Apply."
        } else if snapshot.conflict {
            report.summary = "Routing conflict"
            report.suggestedFix = "Tap Repair routes on Overview, or Disconnect All and Connect All again."
        } else if dualVPNHealthy {
            report.summary = "Healthy — Kerio split + external VPN coexistence"
            report.suggestedFix = "Corporate CIDRs use Kerio (\(snapshot.kerioInterface.isEmpty ? "tunnel" : snapshot.kerioInterface)); general internet uses \(snapshot.defaultInterface). No action needed."
        } else if isActive && snapshot.hasKerioTunnel {
            report.summary = "Healthy — Kerio tunnel + split look good"
            report.suggestedFix = ""
        } else if !helperReady {
            report.summary = "Setup incomplete"
            report.suggestedFix = "Install the route helper (one Mac password)."
        } else {
            report.summary = "Idle — waiting for Kerio"
            report.suggestedFix = "Connect Kerio, then Connect All."
        }

        return report
    }

    // MARK: - Parsers

    private static func parseKerioSession(_ ncList: String) -> (connected: Bool, label: String) {
        let sessions = parseAllVPNSessions(ncList).filter { $0.kind == .kerio }
        if let up = sessions.first(where: \.isConnected) {
            return (true, up.name)
        }
        return (false, sessions.first?.name ?? "")
    }

    private static func parseAllVPNSessions(_ ncList: String) -> [VPNSession] {
        var out: [VPNSession] = []
        for line in ncList.split(separator: "\n").map(String.init) {
            // * (Connected) UUID VPN (com.foo.bar) "Name" [VPN:com.foo.bar]
            let lowerLine = line.lowercased()
            guard lowerLine.contains("vpn") || lowerLine.contains("kerio") else { continue }

            let connected = lowerLine.contains("(connected)")
                || lowerLine.contains("(connecting)")
                || lowerLine.contains("(reasserting)")
            let disconnected = lowerLine.contains("(disconnected)")
                || lowerLine.contains("(disconnecting)")
                || lowerLine.contains("(invalid)")
            // Skip unknown states unless clearly Kerio-related with Connected-like wording
            guard connected || disconnected else { continue }

            var provider = ""
            if let open = line.range(of: "VPN ("), let close = line[open.upperBound...].firstIndex(of: ")") {
                provider = String(line[open.upperBound..<close])
            }
            if provider.isEmpty, let bracket = line.range(of: "[VPN:") {
                let rest = line[bracket.upperBound...]
                if let end = rest.firstIndex(of: "]") {
                    provider = String(rest[..<end])
                }
            }

            var name = ""
            if let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") {
                name = String(line[line.index(after: q1)..<q2]).trimmingCharacters(in: .whitespaces)
            }
            if name.isEmpty {
                name = provider.split(separator: ".").last.map(String.init) ?? "VPN"
            }

            let lower = (provider + " " + name + " " + line).lowercased()
            let kind: VPNSession.Kind
            if lower.contains("kerio") {
                kind = .kerio
            } else if lower.contains("clash") || lower.contains("karing") || lower.contains("sing")
                        || lower.contains("v2box") || lower.contains("shadowrocket")
                        || lower.contains("sfovpn") {
                kind = .outbound
            } else if provider.isEmpty {
                kind = .unknown
            } else {
                kind = .system
            }

            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let uuid = tokens.first(where: { $0.count > 20 && $0.contains("-") }) ?? "\(provider)-\(name)"
            let id = "\(uuid)-\(provider)-\(name)"
            if out.contains(where: { $0.id == id }) { continue }

            // "Connecting" counts as up for Kerio detection so Connect All can proceed
            let isUp = connected && !disconnected
            out.append(VPNSession(
                id: id,
                name: name.isEmpty ? (kind == .kerio ? "Kerio VPN" : "VPN") : name,
                provider: provider,
                isConnected: isUp,
                kind: kind,
                detail: isUp ? "Connected" : "Disconnected"
            ))
        }
        return out.sorted { a, b in
            if a.isConnected != b.isConnected { return a.isConnected && !b.isConnected }
            if a.kind != b.kind {
                let order: [VPNSession.Kind: Int] = [.kerio: 0, .outbound: 1, .system: 2, .unknown: 3]
                return (order[a.kind] ?? 9) < (order[b.kind] ?? 9)
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func findIfaceForVPNRoutes(
        _ vpnRoutes: [String],
        routes: String,
        ignore: Set<String>
    ) -> (iface: String, gateway: String, matched: [String])? {
        var bestIface = ""
        var bestGw = ""
        var matched: [String] = []
        for cidr in vpnRoutes {
            if let hit = routeHit(for: cidr, routes: routes), !ignore.contains(hit.iface) {
                matched.append(cidr)
                if bestIface.isEmpty {
                    bestIface = hit.iface
                    bestGw = hit.gateway
                }
            }
        }
        guard !bestIface.isEmpty else { return nil }
        return (bestIface, bestGw, matched)
    }

    private static func routeHit(for cidr: String, routes: String) -> (gateway: String, iface: String)? {
        let keys = routeKeys(for: cidr)
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 4 else { continue }
            let dest = parts[0]
            guard keys.contains(where: { dest == $0 || dest.hasPrefix($0) }) else { continue }
            let gw = parts[1]
            let iface = parts.last ?? ""
            if iface.hasPrefix("utun") || iface.hasPrefix("kvnet") || iface.hasPrefix("kerio") || iface.hasPrefix("ipsec") {
                return (gw == "link#" || gw.hasPrefix("link") ? "" : gw, iface)
            }
        }
        return nil
    }

    private static func routeKeys(for cidr: String) -> [String] {
        // netstat shortens 192.168.70.0/24 → 192.168.70
        if let slash = cidr.firstIndex(of: "/") {
            let ip = String(cidr[..<slash])
            let prefix = Int(cidr[cidr.index(after: slash)...]) ?? 32
            let octets = ip.split(separator: ".").map(String.init)
            guard octets.count == 4 else { return [cidr, ip] }
            if prefix >= 24 { return [cidr, ip, "\(octets[0]).\(octets[1]).\(octets[2])"] }
            if prefix >= 16 { return [cidr, ip, "\(octets[0]).\(octets[1])"] }
            return [cidr, ip, octets[0]]
        }
        return [cidr]
    }

    private static func classifyVPNRoutes(_ vpnRoutes: [String], routes: String) -> (present: [String], missing: [String]) {
        var present: [String] = []
        var missing: [String] = []
        for cidr in vpnRoutes {
            if routeTableContains(cidr, routes: routes) {
                present.append(cidr)
            } else {
                missing.append(cidr)
            }
        }
        return (present, missing)
    }

    private static func routeTableContains(_ cidr: String, routes: String) -> Bool {
        routeHit(for: cidr, routes: routes) != nil || routes.contains(cidr)
    }

    private static func parseDefaults(routes: String, into snap: inout NetworkSnapshot) {
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 4, parts[0] == "default" else { continue }
            let gw = parts[1]
            let iface = parts.last ?? ""
            if iface.hasPrefix("en"), snap.lanGateway.isEmpty {
                snap.lanGateway = gw
                snap.lanInterface = iface
            }
            if snap.defaultGateway.isEmpty {
                snap.defaultGateway = gw
                snap.defaultInterface = iface
            }
        }
        if snap.lanGateway.isEmpty {
            snap.lanGateway = snap.defaultGateway
            snap.lanInterface = snap.defaultInterface
        }
    }

    private static func ipv4TunnelIfaces(from ifconfig: String) -> [String] {
        var out: [String] = []
        var current: String?
        for raw in ifconfig.split(separator: "\n") {
            let line = String(raw)
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon])
                if name.hasPrefix("utun") || name.hasPrefix("kvnet") || name.hasPrefix("kerio") || name.hasPrefix("ipsec") {
                    current = name
                    // Same-line inet (rare)
                    if line.range(of: #"inet \d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
                        out.append(name)
                        current = nil
                    }
                    continue
                }
            }
            guard let iface = current else { continue }
            if line.hasPrefix("\t") || line.hasPrefix(" ") {
                if line.range(of: #"inet \d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
                    out.append(iface)
                    current = nil
                }
            } else if !line.isEmpty {
                current = nil
            }
        }
        return Array(Set(out))
    }

    private static func interfaceHasIPv4(_ iface: String, ifconfig: String) -> Bool {
        !ipv4OnIface(iface, ifconfig: ifconfig).isEmpty
    }

    private static func ipv4OnIface(_ iface: String, ifconfig: String) -> String {
        var inBlock = false
        for raw in ifconfig.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix(iface + ":") { inBlock = true; continue }
            if inBlock {
                if !line.hasPrefix("\t") && !line.hasPrefix(" ") && !line.isEmpty { break }
                if let r = line.range(of: #"inet (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(line[r]).replacingOccurrences(of: "inet ", with: "")
                }
            }
        }
        return ""
    }

    private static func gatewayForPrefix(_ prefix: String, routes: String) -> String? {
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0] == prefix else { continue }
            let gw = parts[1]
            if gw.hasPrefix("link") { continue }
            return gw
        }
        return nil
    }

    private static func interfaceForPrefix(_ prefix: String, routes: String) -> String? {
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0] == prefix else { continue }
            return parts.last
        }
        return nil
    }

    private static func gatewayFromIface(_ iface: String, ifconfig: String, routes: String) -> String {
        // Prefer gateway seen on routes for this iface
        for line in routes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 4, parts.last == iface else { continue }
            let gw = parts[1]
            if gw.contains("."), !gw.hasPrefix("link") { return gw }
        }
        let ip = ipv4OnIface(iface, ifconfig: ifconfig)
        let parts = ip.split(separator: ".")
        if parts.count == 4 {
            return "\(parts[0]).\(parts[1]).\(parts[2]).1"
        }
        return ""
    }

    private static func currentDNS() -> [String] {
        let out = HelperService.runProcess("/usr/sbin/scutil", ["--dns"], timeoutSeconds: 3).text
        var servers: [String] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("nameserver["), let ip = trimmed.split(separator: ":").last {
                let s = ip.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty, !servers.contains(s) { servers.append(s) }
            }
            if servers.count >= 6 { break }
        }
        return servers
    }
}
