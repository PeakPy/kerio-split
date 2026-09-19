import SwiftUI

/// Realtime map of this Mac ↔ LAN ↔ active VPNs (idle Kerio profiles collapsed).
struct VPNTopologyView: View {
    let snapshot: NetworkSnapshot
    let splitActive: Bool
    let outboundConnected: Bool
    var onRefresh: () -> Void
    /// When true, omit outer card/header — for embedding inside NetworkPulsePanel.
    var embedded: Bool = false

    @State private var pulse = false

    /// Connected sessions first; idle Kerio/same-provider profiles collapsed into one chip.
    private var displaySessions: [DisplaySession] {
        Self.collapseSessions(snapshot.vpnSessions, outboundConnected: outboundConnected)
    }

    private var connectedCount: Int {
        displaySessions.filter(\.active).count
    }

    var body: some View {
        Group {
            if embedded {
                embeddedBody
            } else {
                SurfaceCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Divider().opacity(0.45)
                        diagramBlock
                        Divider().opacity(0.45)
                        legendStrip
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var embeddedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            diagramBlock
            legendStrip
                .padding(.top, 4)
        }
    }

    private var diagramBlock: some View {
        AdaptiveTopologyDiagram(
            snapshot: snapshot,
            splitActive: splitActive,
            sessions: displaySessions,
            pulse: pulse
        )
        .padding(.horizontal, embedded ? 4 : 14)
        .padding(.vertical, embedded ? 8 : 14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Network map")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            liveBadge
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh VPN map")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        let active = connectedCount
        let idleCount = snapshot.vpnSessions.filter { !$0.isConnected }.count
        if active == 0 {
            return idleCount > 0
                ? "No VPN connected · \(idleCount) idle profile\(idleCount == 1 ? "" : "s")"
                : "No system VPN profiles found"
        }
        if idleCount > 0 {
            return "\(active) connected · \(idleCount) idle hidden"
        }
        return "\(active) connected · live"
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Brand.success)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 1 : 0.35)
                .scaleEffect(pulse ? 1.15 : 1)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.success)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Brand.success.opacity(0.12)))
    }

    private var legendStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displaySessions) { session in
                    legendChip(
                        title: session.title,
                        detail: session.chipDetail,
                        active: session.active,
                        color: session.accent
                    )
                }
                if splitActive {
                    legendChip(title: "Split", detail: "Kerio CIDRs", active: true, color: Brand.success)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func legendChip(title: String, detail: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(active ? color : Brand.muted.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.field)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? color.opacity(0.35) : Brand.line, lineWidth: 1)
                )
        )
    }

    // MARK: - Collapse logic

    struct DisplaySession: Identifiable {
        enum Kind { case vpn, outbound, placeholder }
        let id: String
        let title: String
        let detail: String
        let chipDetail: String
        let icon: String
        let accent: Color
        let active: Bool
        let kind: Kind
    }

    static func collapseSessions(_ sessions: [VPNSession], outboundConnected: Bool) -> [DisplaySession] {
        var out: [DisplaySession] = []

        let connected = sessions.filter(\.isConnected)
        let idle = sessions.filter { !$0.isConnected }

        for s in connected {
            out.append(DisplaySession(
                id: s.id,
                title: s.shortProvider,
                detail: shortEndpoint(s.name),
                chipDetail: shortEndpoint(s.name),
                icon: icon(for: s.kind),
                accent: accent(for: s.kind),
                active: true,
                kind: .vpn
            ))
        }

        if outboundConnected, !out.contains(where: { $0.title == "Outbound" }) {
            out.append(DisplaySession(
                id: "builtin-outbound",
                title: "Outbound",
                detail: "Built-in · Connected",
                chipDetail: "Built-in",
                icon: "arrow.up.right.circle.fill",
                accent: Brand.warn,
                active: true,
                kind: .outbound
            ))
        }

        // Hide idle nodes when anything is connected — keeps the map readable.
        if connected.isEmpty {
            var idleByProvider: [String: [VPNSession]] = [:]
            for s in idle {
                idleByProvider[s.shortProvider, default: []].append(s)
            }
            for (provider, group) in idleByProvider.sorted(by: { $0.key < $1.key }) {
                let sample = group[0]
                let n = group.count
                out.append(DisplaySession(
                    id: "idle-\(provider)",
                    title: provider,
                    detail: n == 1 ? "Idle profile" : "\(n) idle profiles",
                    chipDetail: n == 1 ? "Idle" : "\(n) idle",
                    icon: icon(for: sample.kind),
                    accent: Brand.muted,
                    active: false,
                    kind: .vpn
                ))
            }
        }

        if out.isEmpty {
            out.append(DisplaySession(
                id: "empty",
                title: "No VPN",
                detail: "Connect Kerio to appear",
                chipDetail: "—",
                icon: "network.slash",
                accent: Brand.muted,
                active: false,
                kind: .placeholder
            ))
        }

        return out
    }

    private static func shortEndpoint(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(26)) + "…"
    }

    private static func icon(for kind: VPNSession.Kind) -> String {
        switch kind {
        case .kerio: return "building.2.fill"
        case .outbound: return "globe.badge.chevron.backward"
        case .system: return "lock.shield.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private static func accent(for kind: VPNSession.Kind) -> Color {
        switch kind {
        case .kerio: return Brand.primary
        case .outbound: return Brand.warn
        case .system: return Color(red: 0xfb / 255, green: 0x92 / 255, blue: 0x3c / 255)
        case .unknown: return Brand.muted
        }
    }
}

// MARK: - Adaptive diagram (wide map vs compact stack)

private struct AdaptiveTopologyDiagram: View {
    let snapshot: NetworkSnapshot
    let splitActive: Bool
    let sessions: [VPNTopologyView.DisplaySession]
    let pulse: Bool

    /// Below this width, switch to vertical stack so cards never collide.
    private let compactBreakpoint: CGFloat = 560

    var body: some View {
        Group {
            // Prefer wide map when there is room; otherwise stack vertically.
            ViewThatFits(in: .horizontal) {
                wideMapFixed
                    .frame(minWidth: compactBreakpoint)
                compactStack
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Brand.deep.opacity(0.05),
                            Brand.primary.opacity(0.06),
                            Brand.mist.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Compact — vertical flow, no absolute overlap

    private var compactStack: some View {
        VStack(spacing: 10) {
            TopologyNodeCard(
                title: "LAN",
                detail: snapshot.lanInterface.isEmpty
                    ? "Offline"
                    : "\(snapshot.lanInterface) · \(snapshot.lanGateway)",
                icon: "wifi",
                accent: Brand.primarySoft,
                active: !snapshot.lanInterface.isEmpty,
                pulse: pulse,
                compact: true
            )

            compactConnector(active: !snapshot.lanInterface.isEmpty, accent: Brand.primarySoft)

            TopologyHub(
                splitActive: splitActive,
                tunnelLabel: snapshot.kerioInterface.isEmpty ? "This Mac" : snapshot.kerioInterface,
                pulse: pulse,
                compact: true
            )

            ForEach(sessions) { session in
                compactConnector(active: session.active, accent: session.accent)
                TopologyNodeCard(
                    title: session.title,
                    detail: session.detail,
                    icon: session.icon,
                    accent: session.accent,
                    active: session.active,
                    pulse: pulse,
                    compact: true
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
    }

    private func compactConnector(active: Bool, accent: Color) -> some View {
        Rectangle()
            .fill(active ? accent.opacity(pulse ? 0.7 : 0.35) : Brand.line)
            .frame(width: active ? 2.5 : 1.5, height: 14)
            .frame(maxWidth: .infinity)
    }

    // MARK: Wide — horizontal map with safe gutters

    private var wideMapFixed: some View {
        let vpnCount = max(sessions.count, 1)
        let mapHeight = CGFloat(min(320, 180 + vpnCount * 70))

        return GeometryReader { geo in
            wideMap(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: mapHeight)
    }

    private func wideMap(width: CGFloat, height: CGFloat) -> some View {
        // Reserve space for cards so they never collide with the hub.
        let cardW = min(188, max(140, width * 0.26))
        let hubClearance: CGFloat = 88
        let gutter: CGFloat = 14

        let lanCenterX = gutter + cardW / 2
        let vpnCenterX = width - gutter - cardW / 2
        // Hub stays between cards with a hard gap
        let minHubX = lanCenterX + cardW / 2 + hubClearance / 2 + 20
        let maxHubX = vpnCenterX - cardW / 2 - hubClearance / 2 - 20
        let hubX: CGFloat = {
            if minHubX <= maxHubX {
                return (minHubX + maxHubX) / 2
            }
            // Extremely tight — still keep mid
            return width / 2
        }()

        let center = CGPoint(x: hubX, y: height * 0.5)
        let lanPoint = CGPoint(x: lanCenterX, y: height * 0.5)

        let count = max(sessions.count, 1)
        let topPad: CGFloat = 36
        let bottomPad: CGFloat = 36
        let span = max(height - topPad - bottomPad, 48)

        return ZStack {
            TopologyLink(
                from: center,
                to: lanPoint,
                active: !snapshot.lanInterface.isEmpty,
                accent: Brand.primarySoft,
                pulse: pulse
            )

            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                let y = topPad + span * (CGFloat(index) + 0.5) / CGFloat(count)
                let point = CGPoint(x: vpnCenterX, y: y)
                TopologyLink(
                    from: center,
                    to: point,
                    active: session.active,
                    accent: session.accent,
                    pulse: pulse
                )
            }

            TopologyNodeCard(
                title: "LAN",
                detail: snapshot.lanInterface.isEmpty
                    ? "Offline"
                    : "\(snapshot.lanInterface) · \(snapshot.lanGateway)",
                icon: "wifi",
                accent: Brand.primarySoft,
                active: !snapshot.lanInterface.isEmpty,
                pulse: pulse,
                compact: false,
                fixedWidth: cardW
            )
            .position(lanPoint)

            TopologyHub(
                splitActive: splitActive,
                tunnelLabel: snapshot.kerioInterface.isEmpty ? "This Mac" : snapshot.kerioInterface,
                pulse: pulse,
                compact: false
            )
            .position(center)

            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                let y = topPad + span * (CGFloat(index) + 0.5) / CGFloat(count)
                let point = CGPoint(x: vpnCenterX, y: y)
                TopologyNodeCard(
                    title: session.title,
                    detail: session.detail,
                    icon: session.icon,
                    accent: session.accent,
                    active: session.active,
                    pulse: pulse,
                    compact: false,
                    fixedWidth: cardW
                )
                .position(point)
            }
        }
    }
}

// MARK: - Pieces

private struct TopologyHub: View {
    let splitActive: Bool
    let tunnelLabel: String
    let pulse: Bool
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            ZStack {
                Circle()
                    .fill(Brand.heroGradient)
                    .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)
                    .shadow(color: Brand.deep.opacity(0.28), radius: 12, y: 4)
                if splitActive {
                    Circle()
                        .stroke(Brand.success.opacity(pulse ? 0.75 : 0.28), lineWidth: 2)
                        .frame(width: compact ? 68 : 76, height: compact ? 68 : 76)
                }
                Image(systemName: "laptopcomputer")
                    .font(.system(size: compact ? 20 : 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 2) {
                Text("This Mac")
                    .font(.system(size: compact ? 11 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text(splitActive ? "Split ON · \(tunnelLabel)" : tunnelLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// Compact card — title + detail inside the box so labels never collide.
private struct TopologyNodeCard: View {
    let title: String
    let detail: String
    let icon: String
    let accent: Color
    let active: Bool
    let pulse: Bool
    var compact: Bool = false
    var fixedWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? accent : Brand.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(active ? Brand.ink.opacity(0.65) : Brand.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(active ? accent : Brand.muted.opacity(0.35))
                .frame(width: 7, height: 7)
                .opacity(active && pulse ? 1 : 0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 10 : 11)
        .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
        .frame(width: compact ? nil : fixedWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(active ? accent.opacity(0.55) : Brand.line, lineWidth: active ? 1.5 : 1)
                )
                .shadow(color: active ? accent.opacity(0.16) : .clear, radius: pulse ? 10 : 4, y: 2)
        )
        .opacity(active ? 1 : 0.72)
        .animation(.easeInOut(duration: 0.35), value: active)
    }
}

private struct TopologyLink: View {
    let from: CGPoint
    let to: CGPoint
    let active: Bool
    let accent: Color
    let pulse: Bool

    var body: some View {
        Path { path in
            path.move(to: from)
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 6)
            path.addQuadCurve(to: to, control: mid)
        }
        .stroke(
            active ? accent.opacity(pulse ? 0.85 : 0.45) : Brand.line,
            style: StrokeStyle(lineWidth: active ? 2.2 : 1.1, lineCap: .round, dash: active ? [] : [4, 5])
        )
        .animation(.easeInOut(duration: 0.4), value: active)
    }
}
