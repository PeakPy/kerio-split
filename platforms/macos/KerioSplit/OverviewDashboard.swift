import SwiftUI

/// Overview home for Kerio Split.
struct OverviewDashboard: View {
    @ObservedObject var controller: TunnelController
    var onNavigate: (AppSection) -> Void
    @StateObject private var resources = ResourceMonitor()
    @StateObject private var throughput = ThroughputMonitor()

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                heroBanner
                processCard
                NetworkPulsePanel(
                    snapshot: controller.networkSnapshot,
                    splitActive: controller.isActive,
                    outboundConnected: controller.outboundConnected,
                    series: throughput.series,
                    onRefresh: {
                        controller.probeNetwork()
                        controller.refreshDiagnostics()
                        syncThroughputTargets()
                    }
                )
                liveRow
                systemCard
                workspaceRow
            }
        }
        .onAppear {
            resources.start()
            syncThroughputTargets()
        }
        .onDisappear {
            resources.stop()
            throughput.stop()
        }
        .onChange(of: controller.networkSnapshot.kerioInterface) { _ in syncThroughputTargets() }
        .onChange(of: controller.networkSnapshot.defaultInterface) { _ in syncThroughputTargets() }
        .onChange(of: controller.isActive) { _ in syncThroughputTargets() }
        .onChange(of: controller.outboundConnected) { _ in syncThroughputTargets() }
    }

    private func syncThroughputTargets() {
        var targets: [(id: String, title: String, iface: String, accent: Color)] = []
        let snap = controller.networkSnapshot

        if !snap.kerioInterface.isEmpty {
            targets.append((id: "kerio", title: "Kerio", iface: snap.kerioInterface, accent: Brand.primary))
        }

        let outboundIfaces = snap.secondaryTuns.filter { $0 != snap.kerioInterface }
        if let first = outboundIfaces.first {
            let title: String = {
                if !controller.outboundActiveName.isEmpty { return controller.outboundActiveName }
                if controller.outboundConnected { return "Outbound" }
                return snap.vpnSessions.first(where: { $0.isConnected && $0.kind != .kerio })?.shortProvider
                    ?? "External VPN"
            }()
            targets.append((id: "outbound", title: title, iface: first, accent: Brand.warn))
        } else if !snap.defaultOnLAN, snap.defaultInterface.hasPrefix("utun"), snap.defaultInterface != snap.kerioInterface {
            let title = controller.outboundActiveName.isEmpty ? "Internet VPN" : controller.outboundActiveName
            targets.append((id: "default-tun", title: title, iface: snap.defaultInterface, accent: Brand.warn))
        }

        if !snap.lanInterface.isEmpty {
            targets.append((id: "lan", title: "LAN", iface: snap.lanInterface, accent: Brand.primarySoft))
        }

        throughput.start(tracking: Array(targets.prefix(3)))
    }
    // MARK: - Hero

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Brand.heroGradient)
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            BrandLogo(size: 120, style: .mark)
                .opacity(0.16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    statusChip(title: controller.isActive ? "Split ON" : "Split OFF", lit: controller.isActive)
                    statusChip(title: controller.helperReady ? "Helper" : "Setup", lit: controller.helperReady)
                    statusChip(
                        title: (controller.kerioSessionConnected || controller.kerioTunnelSeen)
                            ? "Kerio on"
                            : "Kerio off",
                        lit: controller.kerioSessionConnected || controller.kerioTunnelSeen
                    )
                    Spacer(minLength: 0)
                    phaseBadge
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                HStack(alignment: .center, spacing: 14) {
                    BrandLogo(size: 56, style: .badge)
                        .overlay {
                            if controller.sessionPhase == .connecting
                                || controller.sessionPhase == .waitingForPermission
                                || controller.sessionPhase == .disconnecting {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                                    .modifier(SoftPulse())
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kerio Split")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Split tunneling for Kerio Control VPN")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(controller.statusText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !controller.helperReady {
                    Button {
                        controller.installHelper()
                    } label: {
                        Label("Install route helper", systemImage: "key.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.deep)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isBusy)

                    Text("One Mac password, then Connect All stays silent.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                } else if controller.waitingForAccessibility || controller.sessionPhase == .waitingForPermission {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enable Accessibility for Kerio Split — then come back. Connect All continues automatically.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Open Accessibility") { controller.grantClickKerio() }
                                .buttonStyle(.borderedProminent)
                                .tint(.white)
                                .foregroundStyle(Brand.deep)
                            HStack(spacing: 8) {
                                Button("Relaunch & continue") { controller.relaunchToContinueConnect() }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                                Button("Cancel") { controller.cancelConnectAll() }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                DualActionBar(
                    connectEnabled: controller.canConnectAll,
                    disconnectEnabled: controller.canDisconnectAll,
                    connecting: controller.sessionPhase == .connecting || controller.sessionPhase == .waitingForPermission,
                    disconnecting: controller.sessionPhase == .disconnecting,
                    style: .hero,
                    connectTitle: heroConnectTitle,
                    onConnect: { controller.connectAll() },
                    onDisconnect: { controller.requestDisconnect() }
                )
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, minHeight: heroMinHeight, alignment: .leading)
        .shadow(color: Brand.deep.opacity(0.24), radius: 18, y: 8)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: controller.sessionPhase)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: controller.isActive)
        .animation(.easeInOut(duration: 0.25), value: controller.statusText)
    }

    private var heroMinHeight: CGFloat {
        if !controller.helperReady { return 280 }
        if controller.waitingForAccessibility || controller.sessionPhase == .waitingForPermission { return 300 }
        return 228
    }

    private var phaseBadge: some View {
        Text(phaseTitle)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.18)))
    }

    private var phaseTitle: String {
        switch controller.sessionPhase {
        case .idle:
            if !controller.isActive && (controller.kerioSessionConnected || controller.kerioTunnelSeen) {
                return "NEEDS SPLIT"
            }
            return "IDLE"
        case .connecting: return "CONNECTING"
        case .waitingForPermission: return "NEEDS ACCESS"
        case .connected: return controller.isActive ? "ALL ON" : "KERIO ONLY"
        case .disconnecting: return "DISCONNECTING"
        }
    }

    private var heroConnectTitle: String {
        if controller.kerioSessionConnected || controller.kerioTunnelSeen {
            return "Apply Split"
        }
        return "Connect All"
    }

    private func statusChip(title: String, lit: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                if lit {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .modifier(SoftPulse())
                        .id("pulse-\(title)")
                }
                Circle()
                    .fill(lit ? Color.white : Color.white.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(lit ? 0.22 : 0.14))
        )
        .animation(.easeInOut(duration: 0.3), value: lit)
    }

    // MARK: - Process

    private var processCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    SectionLabel(
                        title: controller.scenario.title,
                        subtitle: controller.scenario.detail
                    )
                    Spacer(minLength: 8)
                    scenarioToneBadge
                }

                if !controller.scenario.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(controller.scenario.actions.enumerated()), id: \.element.id) { index, action in
                            Button(action.title) {
                                controller.performScenarioAction(action)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(index == 0 ? Brand.deep : Brand.muted)
                            .controlSize(index == 0 ? .regular : .small)
                        }
                    }
                    .disabled(controller.isBusy && controller.sessionPhase != .waitingForPermission)
                }

                if controller.sessionPhase == .connecting || controller.sessionPhase == .waitingForPermission
                    || controller.sessionPhase == .disconnecting
                    || (!controller.isActive && (controller.kerioSessionConnected || controller.kerioTunnelSeen)) {
                    ProcessTimeline(steps: controller.processSteps, phase: controller.sessionPhase)
                        .animation(.spring(response: 0.44, dampingFraction: 0.86), value: controller.processSteps)
                }
            }
        }
    }

    private var scenarioToneBadge: some View {
        let color: Color = {
            switch controller.scenario.tone {
            case .good: return Brand.success
            case .warn: return Brand.warn
            case .danger: return Brand.danger
            case .info: return Brand.primary
            case .neutral: return Brand.muted
            }
        }()
        return Text(controller.scenario.scenario.rawValue)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Live row

    private var liveRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                kerioStatusCard
                healthCard
            }
            VStack(alignment: .leading, spacing: 12) {
                kerioStatusCard
                healthCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kerioStatusCard: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    controller.kerioSessionConnected
                        ? "Kerio connected"
                        : (controller.networkSnapshot.hasKerioTunnel ? "Tunnel up" : "Kerio disconnected"),
                    systemImage: (controller.kerioSessionConnected || controller.networkSnapshot.hasKerioTunnel) ? "network" : "network.slash"
                )
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle((controller.kerioSessionConnected || controller.networkSnapshot.hasKerioTunnel) ? Brand.primary : Brand.muted)

                networkSenseLines

                HStack(spacing: 8) {
                    Button("Refresh") {
                        controller.probeNetwork()
                        controller.refreshHelperStatus(forceLog: true)
                        syncThroughputTargets()
                    }
                    if !controller.kerioTunnelSeen {
                        Button("Open Kerio") { controller.openKerioClient() }
                    }
                    if controller.networkSnapshot.conflict {
                        Button("Repair") { controller.repairRoutes() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var healthCard: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Health")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text(controller.connectivity.detail.isEmpty ? "Probing…" : controller.connectivity.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    miniStat(title: "CPU", value: resources.cpuText)
                    miniStat(title: "App RAM", value: resources.appMemoryText)
                    miniStat(title: "Mem", value: String(format: "%.0f%%", resources.systemPercent))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var networkSenseLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(networkDetail)
                .font(.system(size: 11))
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.networkSnapshot.kerioInterface.isEmpty {
                Text("Kerio \(controller.networkSnapshot.kerioInterface) · gw \(controller.networkSnapshot.kerioGateway)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Brand.muted)
            }
            Text("Default \(controller.networkSnapshot.defaultInterface.isEmpty ? "?" : controller.networkSnapshot.defaultInterface) · hijack \(controller.networkSnapshot.fullTunnelHijack ? "yes" : "no")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Brand.muted)
            if !controller.networkSnapshot.secondaryTuns.isEmpty {
                Text("Other tun: \(controller.networkSnapshot.secondaryTuns.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Brand.warn)
            }
        }
    }

    private var networkDetail: String {
        if controller.networkSnapshot.conflict {
            return controller.networkSnapshot.conflictDetail
        }
        if controller.kerioSessionConnected {
            let label = controller.kerioSessionLabel.isEmpty ? "Kerio" : controller.kerioSessionLabel
            if controller.isActive {
                return "Session Connected (\(label)) · split ON"
            }
            return "Session Connected (\(label)) · tap Apply Split once — Kerio alone is not enough"
        }
        if controller.isActive {
            if controller.networkSnapshot.hasExternalOutbound {
                return "Split ON · external outbound detected — Kerio CIDRs guarded"
            }
            return "Split ON · corporate CIDRs on Kerio · internet on LAN"
        }
        if controller.kerioTunnelSeen {
            if controller.fullTunnelHijackSeen {
                return "VPN is routing everything — Connect All to restore split"
            }
            return "Tunnel interface up · tap Connect All to apply split"
        }
        return "Kerio session is Disconnected. Connect in Kerio, then Connect All."
    }

    private func miniStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.field)
        )
    }

    // MARK: - System

    private var systemCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(
                    title: "System",
                    subtitle: controller.helperReady
                        ? "Route helper is passwordless. Connect All opens the official Kerio client."
                        : "Install the route helper once — that is the only Mac password prompt."
                )

                HStack(spacing: 8) {
                    systemPill(title: controller.helperReady ? "Helper ready" : "Helper needed", lit: controller.helperReady)
                    systemPill(title: controller.canClickKerio ? "Can click Kerio" : "Accessibility off", lit: controller.canClickKerio)
                    systemPill(title: "\(controller.config.vpnRoutes.count) VPN routes", lit: !controller.config.vpnRoutes.isEmpty)
                }

                if !controller.canClickKerio {
                    Text("Enable this copy in Privacy → Accessibility, then Relaunch. An older Kerio Split toggle does not count.")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(KerioLauncher.runningAppPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                        .textSelection(.enabled)
                    ButtonRow {
                        Button("Open Accessibility") { controller.grantClickKerio() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.deep)
                        Button("Relaunch") { controller.relaunchApp() }
                            .buttonStyle(.bordered)
                    }
                }

                ButtonRow {
                    Button("Open Kerio") { controller.openKerioClient() }
                        .buttonStyle(.bordered)
                    Button("Recheck helper") { controller.refreshHelperStatus(forceLog: true) }
                        .buttonStyle(.bordered)
                    Button("VPN settings") { onNavigate(.settings) }
                        .buttonStyle(.bordered)
                }
                .disabled(controller.isBusy)
            }
        }
    }

    private func systemPill(title: String, lit: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(lit ? Brand.primary : Brand.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(lit ? Brand.primary.opacity(0.12) : Brand.field)
            )
    }

    // MARK: - Workspace

    private var workspaceRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 10)],
            spacing: 10
        ) {
            ShortcutTile(title: "VPN Routes", subtitle: "\(controller.config.vpnRoutes.count) via Kerio", icon: "point.3.connected.trianglepath.dotted", action: { onNavigate(.vpnRoutes) })
            ShortcutTile(title: "Bypass", subtitle: "\(controller.config.bypassRoutes.count) stay on LAN", icon: "arrow.triangle.branch", action: { onNavigate(.bypass) })
            ShortcutTile(title: "Outbound", subtitle: controller.config.options.outboundMode.title, icon: "arrow.up.right.circle.fill", action: { onNavigate(.outbound) })
            ShortcutTile(title: "Settings", subtitle: "Pin, guard, DNS", icon: "gearshape.fill", action: { onNavigate(.settings) })
            ShortcutTile(title: "Activity", subtitle: "Engine + network events", icon: "list.bullet.rectangle", action: { onNavigate(.activity) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Brand.heroGradient)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.muted)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Brand.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SoftPulse: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.7 : 1)
            .opacity(on ? 0 : 0.7)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    on = true
                }
            }
    }
}
