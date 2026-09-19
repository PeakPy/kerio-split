import Foundation
import Network

/// Parsed share-link endpoint used for config build + TCP latency probes.
struct ShareLinkEndpoint: Equatable {
    var scheme: String
    var host: String
    var port: Int
    var userInfo: String
    var query: [String: String]

    static func parse(_ link: String) -> ShareLinkEndpoint? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("vmess://") {
            let b64 = String(trimmed.dropFirst("vmess://".count))
            let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
            guard let data = Data(base64Encoded: b64) ?? Data(base64Encoded: padded),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let host = obj["add"] as? String ?? ""
            guard !host.isEmpty else { return nil }
            let port = Int(obj["port"] as? String ?? "") ?? (obj["port"] as? Int ?? 443)
            return ShareLinkEndpoint(
                scheme: "vmess",
                host: host,
                port: port,
                userInfo: obj["id"] as? String ?? "",
                query: [:]
            )
        }

        // URLComponents mishandles some vless fragments; strip fragment for parsing.
        let withoutFrag: String
        if let hash = trimmed.firstIndex(of: "#") {
            withoutFrag = String(trimmed[..<hash])
        } else {
            withoutFrag = trimmed
        }
        guard let comps = URLComponents(string: withoutFrag),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return ShareLinkEndpoint(
            scheme: scheme,
            host: host,
            port: comps.port ?? 443,
            userInfo: comps.user ?? "",
            query: query
        )
    }
}

extension OutboundProfile {
    var endpointHostPort: (host: String, port: Int)? {
        guard let ep = ShareLinkEndpoint.parse(shareLink) else { return nil }
        return (ep.host, ep.port)
    }
}

enum OutboundProbe {
    /// TCP connect RTT to host:port in milliseconds. `nil` = timeout / unreachable.
    static func tcpLatency(host: String, port: Int, timeoutSeconds: TimeInterval = 2.5) async -> Int? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "keriosplit.outbound.ping")
            let params = NWParameters.tcp
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .https
            )
            let conn = NWConnection(to: endpoint, using: params)
            let started = Date()
            final class Gate: @unchecked Sendable {
                var finished = false
            }
            let gate = Gate()

            let finish: @Sendable (Int?) -> Void = { ms in
                queue.async {
                    guard !gate.finished else { return }
                    gate.finished = true
                    conn.cancel()
                    continuation.resume(returning: ms)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    finish(max(ms, 1))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(nil)
            }
        }
    }

    /// Probe many profiles with bounded concurrency. Missing keys = unreachable.
    static func pingAll(
        profiles: [OutboundProfile],
        concurrency: Int = 8
    ) async -> [String: Int] {
        var results: [String: Int] = [:]
        var index = 0
        await withTaskGroup(of: (String, Int?).self) { group in
            func enqueueNext() {
                guard index < profiles.count else { return }
                let profile = profiles[index]
                index += 1
                group.addTask {
                    guard let ep = profile.endpointHostPort else { return (profile.id, nil) }
                    let ms = await tcpLatency(host: ep.host, port: ep.port)
                    return (profile.id, ms)
                }
            }

            let initial = min(concurrency, profiles.count)
            for _ in 0..<initial { enqueueNext() }

            for await (id, ms) in group {
                if let ms { results[id] = ms }
                enqueueNext()
            }
        }
        return results
    }
}
