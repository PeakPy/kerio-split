import SwiftUI

/// Professional overview / home dashboard for Kerio Split.
struct OverviewDashboard: View {
    @ObservedObject var controller: TunnelController
    var onNavigate: (AppSection) -> Void
    @StateObject private var resources = ResourceMonitor()

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                heroBanner
                resourceStrip
                networkStrip
                metricsRow
                helperCard
                shortcutsCard
            }
        }
        .onAppear { resources.start() }
        .onDisappear { resources.stop() }
    }

    // MARK: - Resources

    private var resourceStrip: some View {
        SurfaceCard(padding: 12) {
            HStack(spacing: 10) {
                resourceChip(
                    title: "CPU",
                    value: resources.cpuText,
                    detail: "This app",
                    icon: "gauge.with.dots.needle.67percent"
                )
                resourceChip(
                    title: "App RAM",
                    value: resources.appMemoryText,
                    detail: "Resident",
                    icon: "memorychip"
                )
                resourceChip(
                    title: "System memory",
                    value: String(format: "%.0f%%", resources.systemPercent),
                    detail: resources.systemMemoryText,
                    icon: "internaldrive"
                )
            }
        }
    }

    private func resourceChip(title: String, value: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Brand.primary.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.muted)
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.field)
        )
    }

    // MARK: - Network strip

    private var networkStrip: some View {
        SurfaceCard(padding: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(controller.kerioTunnelSeen
                              ? Brand.primary.opacity(0.14)
                              : Brand.field)
                        .frame(width: 40, height: 40)
                    Image(systemName: controller.kerioTunnelSeen ? "network" : "network.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(controller.kerioTunnelSeen ? Brand.primary : Brand.muted)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.kerioTunnelSeen ? "Kerio tunnel detected" : "No Kerio tunnel yet")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Text(networkDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Probe") {
                    controller.probeNetwork()
                    controller.refreshHelperStatus()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isBusy)
            }
        }
    }

    private var networkDetail: String {
        if controller.kerioTunnelSeen {
            let ifaces = controller.tunnelInterfaces.isEmpty
                ? "utun"
                : controller.tunnelInterfaces.joined(separator: ", ")
            if controller.fullTunnelHijackSeen && !controller.isActive {
                return "\(ifaces) · full-tunnel hijack still present — Connect Split to fix"
            }
            if controller.isActive {
                return "\(ifaces) · split routes active"
            }
            return "\(ifaces) · connect split when ready"
        }
        return "Connect Kerio Control VPN Client, then enable split tunneling here."
    }

    // MARK: - Hero

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.heroGradient)
                .overlay {
                    // Soft light sweep — atmosphere, not clutter
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .overlay(alignment: .topTrailing) {
                    Image(nsImage: Brand.logoImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .opacity(0.14)
                        .padding(18)
                }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    statusChip(
                        title: controller.isActive ? "Split ON" : "Split OFF",
                        lit: controller.isActive
                    )
                    statusChip(
                        title: controller.helperReady ? "Helper" : "Setup",
                        lit: controller.helperReady
                    )
                    statusChip(
                        title: controller.kerioTunnelSeen ? "Kerio up" : "Kerio down",
                        lit: controller.kerioTunnelSeen
                    )
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kerio Split")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(controller.statusText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: { controller.toggle() }) {
                    HStack(spacing: 8) {
                        Image(systemName: controller.isBusy
                              ? "hourglass"
                              : (controller.isActive ? "link.badge.minus" : "bolt.fill"))
                        Text(controller.isBusy
                             ? "Working…"
                             : (controller.isActive ? "Disconnect Split" : "Connect Split"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Brand.deep)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(controller.isBusy)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .shadow(color: Brand.deep.opacity(0.22), radius: 16, y: 8)
    }

    private func statusChip(title: String, lit: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(lit ? Color.white : Color.white.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.16))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            MetricTile(
                title: "VPN routes",
                value: "\(controller.config.vpnRoutes.count)",
                icon: "point.3.connected.trianglepath.dotted",
                hint: "Via Kerio",
                action: { onNavigate(.vpnRoutes) }
            )
            MetricTile(
                title: "Bypass",
                value: "\(controller.config.bypassRoutes.count)",
                icon: "arrow.triangle.branch",
                hint: "LAN gateway",
                action: { onNavigate(.bypass) }
            )
            MetricTile(
                title: "Custom DNS",
                value: "\(controller.config.options.customDns.count)",
                icon: "network",
                hint: "While split on",
                action: { onNavigate(.settings) }
            )
        }
    }

    // MARK: - Helper

    private var helperCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(controller.helperReady
                                  ? Brand.success.opacity(0.14)
                                  : Brand.warn.opacity(0.14))
                            .frame(width: 44, height: 44)
                        Image(systemName: controller.helperReady
                              ? "checkmark.shield.fill"
                              : "lock.shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(controller.helperReady ? Brand.success : Brand.warn)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.helperReady ? "Privileged helper ready" : "One-time helper setup")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text(
                            controller.helperReady
                                ? "Connect and disconnect without password prompts."
                                : "Install once with your Mac password. Later actions stay silent."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 0) {
                    helperStep(number: "1", title: "Install", done: controller.helperReady)
                    helperStepDivider(done: controller.helperReady)
                    helperStep(number: "2", title: "Connect Kerio", done: true)
                    helperStepDivider(done: controller.isActive)
                    helperStep(number: "3", title: "Enable split", done: controller.isActive)
                }
                .padding(.vertical, 4)

                ButtonRow {
                    if controller.helperReady {
                        Button("Uninstall helper") { controller.uninstallHelper() }
                            .buttonStyle(.bordered)
                        Button("Recheck") { controller.refreshHelperStatus() }
                            .buttonStyle(.bordered)
                        Button("Refresh routes") { controller.refreshStatus() }
                            .buttonStyle(.bordered)
                    } else {
                        Button {
                            controller.installHelper()
                        } label: {
                            Label("Install helper", systemImage: "key.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.deep)
                        Button("Recheck") { controller.refreshHelperStatus() }
                            .buttonStyle(.bordered)
                    }
                }
                .disabled(controller.isBusy)
            }
        }
    }

    private func helperStep(number: String, title: String, done: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done ? Brand.primary.opacity(0.15) : Brand.field)
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.primary)
                } else {
                    Text(number)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.muted)
                }
            }
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(done ? Brand.ink : Brand.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func helperStepDivider(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Brand.primary.opacity(0.35) : Brand.line)
            .frame(height: 2)
            .frame(maxWidth: 36)
            .padding(.bottom, 16)
    }

    // MARK: - Shortcuts

    private var shortcutsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Workspace", subtitle: "Jump to routes, config, or activity.")

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ShortcutTile(
                        title: "VPN Routes",
                        subtitle: "Hosts via Kerio",
                        icon: "point.3.connected.trianglepath.dotted",
                        action: { onNavigate(.vpnRoutes) }
                    )
                    ShortcutTile(
                        title: "Bypass",
                        subtitle: "Stay on LAN",
                        icon: "arrow.triangle.branch",
                        action: { onNavigate(.bypass) }
                    )
                    ShortcutTile(
                        title: "Settings",
                        subtitle: "DNS & behavior",
                        icon: "gearshape.fill",
                        action: { onNavigate(.settings) }
                    )
                    ShortcutTile(
                        title: "Activity",
                        subtitle: "Engine log",
                        icon: "list.bullet.rectangle",
                        action: { onNavigate(.activity) }
                    )
                }
            }
        }
    }
}

// MARK: - Tiles

private struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Brand.primary.opacity(0.12))
                        )
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                }

                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Brand.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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
