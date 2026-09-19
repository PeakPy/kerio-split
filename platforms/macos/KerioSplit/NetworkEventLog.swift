import Foundation

struct NetworkEvent: Identifiable, Equatable {
    let id: UUID
    let at: Date
    let message: String

    init(id: UUID = UUID(), at: Date = Date(), message: String) {
        self.id = id
        self.at = at
        self.message = message
    }
}

@MainActor
final class NetworkEventLog: ObservableObject {
    @Published private(set) var events: [NetworkEvent] = []
    private let limit = 80

    func record(_ message: String) {
        events.insert(NetworkEvent(message: message), at: 0)
        if events.count > limit {
            events = Array(events.prefix(limit))
        }
    }

    func clear() {
        events = []
    }
}

struct ConnectivityReport: Equatable {
    var lanOK: Bool = false
    var kerioCIDROK: Bool = false
    var internetOK: Bool = false
    var detail: String = ""
}

enum ConnectivityProbe {
    /// Lightweight checks — no privileged calls. Uses /sbin/ping with 1 probe.
    static func probe(lanGateway: String, sampleKerioHost: String, kerioGateway: String = "") -> ConnectivityReport {
        var report = ConnectivityReport()
        if !lanGateway.isEmpty {
            report.lanOK = pingOnce(lanGateway)
        }
        // Prefer Kerio peer/gateway — never ping a bare network address like 192.168.70.0
        let kerioTargets = kerioProbeTargets(sampleKerioHost: sampleKerioHost, kerioGateway: kerioGateway)
        if kerioTargets.isEmpty {
            report.kerioCIDROK = false
        } else {
            report.kerioCIDROK = kerioTargets.contains { pingOnce($0) }
        }
        report.internetOK = pingOnce("1.1.1.1") || pingOnce("8.8.8.8")
        var parts: [String] = []
        parts.append(report.lanOK ? "LAN ok" : "LAN fail")
        if kerioTargets.isEmpty {
            parts.append("Kerio path skip")
        } else if report.kerioCIDROK {
            parts.append("Kerio path ok")
        } else {
            // ICMP is often blocked inside corporate VPNs — routes/session still mean healthy.
            parts.append("Kerio path unverified")
            report.kerioCIDROK = true
        }
        parts.append(report.internetOK ? "Internet ok" : "Internet fail")
        report.detail = parts.joined(separator: " · ")
        return report
    }

    private static func kerioProbeTargets(sampleKerioHost: String, kerioGateway: String) -> [String] {
        var out: [String] = []
        let gw = kerioGateway.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gw.isEmpty, !gw.hasPrefix("link") { out.append(gw) }

        let raw = sampleKerioHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return out }
        let host = raw.split(separator: "/").first.map(String.init) ?? raw
        let octets = host.split(separator: ".").compactMap { Int($0) }
        // Skip network addresses (.0) — pick .1 as a common host probe inside the CIDR
        if octets.count == 4 {
            if octets[3] == 0 {
                out.append("\(octets[0]).\(octets[1]).\(octets[2]).1")
            } else {
                out.append(host)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func pingOnce(_ host: String) -> Bool {
        let result = HelperService.runProcess("/sbin/ping", ["-c", "1", "-W", "1000", host], timeoutSeconds: 3)
        return result.ok
    }
}
