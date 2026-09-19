import SwiftUI

/// Overview home for Kerio Split.
struct OverviewDashboard: View {
    @ObservedObject var controller: TunnelController
    var onNavigate: (AppSection) -> Void
    @StateObject private var resources = ResourceMonitor()

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                heroBanner
                processCard
                liveRow
                systemCard
                workspaceRow
            }
        }
        .onAppear { resources.start() }
        .onDisappear { resources.stop() }
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
                    statusChip(title: controller.kerioTunnelSeen ? "VPN up" : "VPN down", lit: controller.kerioTunnelSeen)
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
        case .idle: return "IDLE"
        case .connecting: return "CONNECTING"
        case .waitingForPermission: return "NEEDS ACCESS"
        case .connected: return "ALL ON"
        case .disconnecting: return "DISCONNECTING"
        }
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
                        title: processTitle,
                        subtitle: processSubtitle
                    )
                    Spacer(minLength: 8)
                    if controller.sessionPhase == .connecting || controller.sessionPhase == .waitingForPermission {
                        Button("Cancel") { controller.cancelConnectAll() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if controller.sessionPhase == .waitingForPermission {
                    Text("Turn on Kerio Split in Privacy → Accessibility, then return to this window. No need to cancel — we resume for you.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    ButtonRow {
                        Button("Open Accessibility") { controller.grantClickKerio() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.deep)
                        Button("Relaunch & continue") { controller.relaunchToContinueConnect() }
                            .buttonStyle(.bordered)
                    }
                }

                if controller.sessionPhase == .idle, controller.helperReady {
                    Text("Ready when you are — Connect All starts Kerio, waits for the VPN, then applies your routes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProcessTimeline(steps: controller.processSteps, phase: controller.sessionPhase)
                        .animation(.spring(response: 0.44, dampingFraction: 0.86), value: controller.processSteps)
                }
            }
        }
    }

    private var processTitle: String {
        switch controller.sessionPhase {
        case .idle: return controller.helperReady ? "Ready" : "Setup needed"
        case .connecting: return "Turning everything on"
        case .waitingForPermission: return "Waiting for Accessibility"
        case .connected: return "All on"
        case .disconnecting: return "Turning everything off"
        }
    }

    private var processSubtitle: String {
        switch controller.sessionPhase {
        case .idle:
            return controller.helperReady
                ? "Connect All starts Kerio, waits for the VPN, then applies split. Disconnect All reverses that."
                : "Install the route helper once. After that, Connect All / Disconnect All stay passwordless."
        case .connecting:
            return "Official Kerio client → VPN tunnel → split routes. Lights turn on in order."
        case .waitingForPermission:
            return "macOS blocks clicking Kerio until this app is allowed. After you enable it, Connect All continues on its own."
        case .connected:
            return "Helper, Kerio session, tunnel, and split are all active."
        case .disconnecting:
            return "Split comes off first, then Kerio Disconnect. Lights turn off after the last step."
        }
    }

    // MARK: - Live row

    private var liveRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.kerioTunnelSeen ? "VPN tunnel" : "No tunnel", systemImage: controller.kerioTunnelSeen ? "network" : "network.slash")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(controller.kerioTunnelSeen ? Brand.primary : Brand.muted)
                    Text(networkDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Refresh network") {
                            controller.probeNetwork()
                            controller.refreshHelperStatus(forceLog: true)
                        }
                        if !controller.kerioTunnelSeen {
                            Button("Open Kerio") { controller.openKerioClient() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.isBusy)
                }
            }

            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This Mac")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    HStack(spacing: 8) {
                        miniStat(title: "CPU", value: resources.cpuText)
                        miniStat(title: "App RAM", value: resources.appMemoryText)
                        miniStat(title: "Mem", value: String(format: "%.0f%%", resources.systemPercent))
                    }
                }
            }
        }
    }

    private var networkDetail: String {
        if controller.kerioTunnelSeen {
            if controller.isActive { return "VPN tunnel up · split routes active" }
            if controller.fullTunnelHijackSeen {
                return "VPN is routing everything — Connect All to restore split"
            }
            return "VPN tunnel up · tap Connect All to apply split"
        }
        return "Connect All opens the official Kerio client, then applies split."
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
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            ShortcutTile(title: "VPN Routes", subtitle: "\(controller.config.vpnRoutes.count) via Kerio", icon: "point.3.connected.trianglepath.dotted", action: { onNavigate(.vpnRoutes) })
            ShortcutTile(title: "Bypass", subtitle: "\(controller.config.bypassRoutes.count) stay on LAN", icon: "arrow.triangle.branch", action: { onNavigate(.bypass) })
            ShortcutTile(title: "Settings", subtitle: "DNS & behavior", icon: "gearshape.fill", action: { onNavigate(.settings) })
            ShortcutTile(title: "Activity", subtitle: "Engine log", icon: "list.bullet.rectangle", action: { onNavigate(.activity) })
        }
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
