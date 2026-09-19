import SwiftUI

struct OutboundDashboard: View {
    @ObservedObject var controller: TunnelController
    @StateObject private var throughput = ThroughputMonitor()
    @State private var importDraft = ""
    @State private var subURL = ""
    @State private var subName = "Subscription"
    @State private var ignoreDraft = ""
    @State private var showImport = false
    @State private var showSubscription = false
    @State private var profileFilter = ""
    @State private var tick = Date()

    private var mode: OutboundMode { controller.config.options.outboundMode }
    private var activeProfile: OutboundProfile? {
        guard let id = controller.outboundStore.activeProfileId else { return nil }
        return controller.outboundStore.profiles.first { $0.id == id }
    }
    private var filteredProfiles: [OutboundProfile] {
        let q = profileFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return controller.outboundStore.profiles }
        return controller.outboundStore.profiles.filter {
            $0.name.lowercased().contains(q) || $0.protocolLabel.lowercased().contains(q)
        }
    }

    private var outboundIface: String {
        let snap = controller.networkSnapshot
        if let t = snap.secondaryTuns.first(where: { $0 != snap.kerioInterface }) { return t }
        if !snap.defaultOnLAN, snap.defaultInterface.hasPrefix("utun"), snap.defaultInterface != snap.kerioInterface {
            return snap.defaultInterface
        }
        return ""
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                connectionHero
                if controller.outboundConnected || !outboundIface.isEmpty {
                    liveSessionSection
                    liveTrafficSection
                }
                modePicker
                if mode == .builtIn {
                    engineCard
                    sessionDetailsCard
                    profilesCard
                    addNodesSection
                } else if mode == .external {
                    externalSection
                    sessionDetailsCard
                } else {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Outbound is off")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text("Kerio Split only manages corporate CIDRs. Switch to Built-in or External when you want a second tunnel for general internet.")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onAppear {
            controller.reloadOutboundStore()
            syncThroughput()
        }
        .onDisappear { throughput.stop() }
        .onChange(of: controller.outboundConnected) { _ in syncThroughput() }
        .onChange(of: controller.networkSnapshot.secondaryTuns) { _ in syncThroughput() }
        .onChange(of: controller.networkSnapshot.defaultInterface) { _ in syncThroughput() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            tick = date
        }
    }

    private func syncThroughput() {
        var targets: [(id: String, title: String, iface: String, accent: Color)] = []
        if !outboundIface.isEmpty {
            let title = controller.outboundActiveName.isEmpty ? "Outbound" : controller.outboundActiveName
            targets.append((id: "outbound", title: title, iface: outboundIface, accent: Brand.warn))
        }
        let snap = controller.networkSnapshot
        if !snap.lanInterface.isEmpty {
            targets.append((id: "lan", title: "LAN", iface: snap.lanInterface, accent: Brand.primarySoft))
        }
        if !snap.kerioInterface.isEmpty {
            targets.append((id: "kerio", title: "Kerio", iface: snap.kerioInterface, accent: Brand.primary))
        }
        throughput.start(tracking: Array(targets.prefix(3)))
    }

    // MARK: - Connection hero

    private var connectionHero: some View {
        let connected = controller.outboundConnected
        let connecting = controller.outboundConnecting
        let accent: Color = {
            if connecting { return Brand.warn }
            if connected { return Brand.success }
            return Brand.muted
        }()

        return SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.15))
                            .frame(width: 56, height: 56)
                        Image(systemName: connecting ? "arrow.triangle.2.circlepath" : (connected ? "checkmark.shield.fill" : "shield.slash"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(heroTitle)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text(heroSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let err = controller.outboundError, !err.isEmpty, !connected {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.danger)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    if connected || connecting {
                        Button {
                            controller.disconnectOutbound()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.danger)
                        .disabled(connecting)
                    }
                }
                .padding(18)

                if connected {
                    Divider().opacity(0.45)
                    HStack(spacing: 12) {
                        if let p = activeProfile {
                            protocolBadge(p.protocolLabel)
                            Text(p.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        } else if !controller.outboundActiveName.isEmpty {
                            Text(controller.outboundActiveName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        Spacer()
                        if !outboundIface.isEmpty {
                            Text(outboundIface)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Brand.muted)
                        }
                        Text("Internet via outbound")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.success)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Live session + traffic

    private var liveSessionSection: some View {
        let series = throughput.series.first { $0.id == "outbound" }
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(
                    title: "Live session",
                    subtitle: controller.outboundConnected
                        ? "Realtime outbound path · updates every second"
                        : "Secondary tunnel detected"
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                    spacing: 10
                ) {
                    detailTile("Status", controller.outboundConnecting ? "Connecting" : (controller.outboundConnected ? "Connected" : "Detected"))
                    detailTile("Profile", controller.outboundActiveName.isEmpty ? (activeProfile?.name ?? "—") : controller.outboundActiveName)
                    detailTile("Protocol", activeProfile?.protocolLabel ?? "—")
                    detailTile("Interface", outboundIface.isEmpty ? "—" : outboundIface)
                    detailTile("Speed", series?.totalText ?? "—")
                    detailTile("Download", series?.downText ?? "—")
                    detailTile("Upload", series?.upText ?? "—")
                    detailTile("Duration", durationText)
                    detailTile("Default route", controller.networkSnapshot.defaultInterface.isEmpty ? "—" : controller.networkSnapshot.defaultInterface)
                    detailTile("Kerio tunnel", controller.networkSnapshot.kerioInterface.isEmpty ? "—" : controller.networkSnapshot.kerioInterface)
                    detailTile("Split", controller.isActive ? "ON" : "OFF")
                    detailTile("Mode", mode.title)
                }
            }
        }
    }

    private var liveTrafficSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(
                title: "Live traffic",
                subtitle: throughput.series.isEmpty
                    ? "Waiting for interface counters…"
                    : "Outbound · LAN · Kerio when present"
            )
            if throughput.series.isEmpty {
                SurfaceCard {
                    Text("Speed graphs appear once a tunnel interface is up.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.muted)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 560), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(throughput.series) { s in
                        ThroughputCard(series: s)
                    }
                }
            }
        }
    }

    private var sessionDetailsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(
                    title: "Connection details",
                    subtitle: "Routing context around outbound + Kerio coexistence"
                )

                detailRow("Outbound status", controller.outboundStatusDetail)
                detailRow("Active profile", controller.outboundActiveName.isEmpty ? (activeProfile?.name ?? "None") : controller.outboundActiveName)
                if let p = activeProfile {
                    detailRow("Protocol", p.protocolLabel)
                    detailRow("Share link", String(p.shareLink.prefix(64)) + (p.shareLink.count > 64 ? "…" : ""))
                }
                detailRow("Outbound iface", outboundIface.isEmpty ? "Not detected" : outboundIface)
                detailRow(
                    "Secondary tunnels",
                    controller.networkSnapshot.secondaryTuns.isEmpty
                        ? "None"
                        : controller.networkSnapshot.secondaryTuns.joined(separator: ", ")
                )
                detailRow(
                    "Default route",
                    "\(controller.networkSnapshot.defaultInterface.isEmpty ? "?" : controller.networkSnapshot.defaultInterface) via \(controller.networkSnapshot.defaultGateway.isEmpty ? "link" : controller.networkSnapshot.defaultGateway)"
                )
                detailRow(
                    "Kerio",
                    controller.networkSnapshot.kerioInterface.isEmpty
                        ? "No Kerio tunnel"
                        : "\(controller.networkSnapshot.kerioInterface) · gw \(controller.networkSnapshot.kerioGateway)"
                )
                detailRow("Ignore list", controller.config.options.ignoreInterfaces.isEmpty ? "Empty" : controller.config.options.ignoreInterfaces.joined(separator: ", "))
                detailRow("Profiles saved", "\(controller.outboundStore.profiles.count)")
                detailRow("Subscriptions", "\(controller.outboundStore.subscriptions.count)")
                if let path = controller.outboundBinaryPath {
                    detailRow("Engine", path)
                }

                HStack(spacing: 8) {
                    Button("Refresh network") {
                        controller.probeNetwork()
                        syncThroughput()
                    }
                    .buttonStyle(.bordered)
                    if controller.outboundConnected {
                        Button("Disconnect outbound") { controller.disconnectOutbound() }
                            .buttonStyle(.bordered)
                            .tint(Brand.danger)
                    }
                }
            }
        }
        // Keep duration label refreshing via tick
        .id(tick.timeIntervalSince1970.rounded())
    }

    private var durationText: String {
        guard let at = controller.outboundConnectedAt else { return "—" }
        let secs = max(0, Int(tick.timeIntervalSince(at)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func detailTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.field)
        )
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.muted)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Brand.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heroTitle: String {
        if controller.outboundConnecting { return "Connecting…" }
        if controller.outboundConnected { return "Connected" }
        if mode == .off { return "Outbound off" }
        if mode == .external { return "External mode" }
        return "Not connected"
    }

    private var heroSubtitle: String {
        if controller.outboundConnecting {
            return controller.outboundStatusDetail
        }
        if controller.outboundConnected {
            return controller.outboundStatusDetail.isEmpty
                ? "General internet uses outbound. Kerio CIDRs stay on Kerio."
                : controller.outboundStatusDetail
        }
        if mode == .builtIn {
            return "Pick a profile below and tap Connect. Kerio corporate routes stay guarded."
        }
        if mode == .external {
            return "Connect in your other VPN app. Kerio Split will detect its tunnel."
        }
        return "Enable Built-in or External to add a second tunnel for general internet."
    }

    // MARK: - Mode

    private var modePicker: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Mode", subtitle: mode.subtitle)
                HStack(spacing: 8) {
                    ForEach(OutboundMode.allCases) { m in
                        modeChip(m)
                    }
                }
            }
        }
    }

    private func modeChip(_ m: OutboundMode) -> some View {
        let on = mode == m
        return Button {
            controller.setOutboundMode(m)
        } label: {
            Text(m.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? .white : Brand.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Brand.deep : Brand.field)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Engine

    private var engineCard: some View {
        SurfaceCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: controller.outboundBinaryPath == nil ? "shippingbox" : "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(controller.outboundBinaryPath == nil ? Brand.warn : Brand.success)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.outboundBinaryPath == nil ? "Engine needed" : "Engine ready")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(engineDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if controller.outboundEngineBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.outboundEngineProgress.isEmpty ? "Working…" : controller.outboundEngineProgress)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                } else if controller.outboundBinaryPath == nil {
                    Button {
                        Task { await controller.installOutboundEngine() }
                    } label: {
                        Label("Install engine", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.deep)
                } else {
                    Button("Reinstall") {
                        Task { await controller.installOutboundEngine() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var engineDetail: String {
        if controller.outboundEngineBusy {
            return controller.outboundEngineProgress.isEmpty
                ? "Downloading outbound engine…"
                : controller.outboundEngineProgress
        }
        if let path = controller.outboundBinaryPath {
            return URL(fileURLWithPath: path).lastPathComponent + " · ready to connect"
        }
        return "One tap downloads sing-box into Application Support. No Terminal."
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(
                        title: "Profiles",
                        subtitle: controller.outboundStore.profiles.isEmpty
                            ? "Import a share link or subscription to get started"
                            : "\(controller.outboundStore.profiles.count) saved · tap Connect on a row"
                    )
                    Spacer()
                    if !controller.outboundStore.profiles.isEmpty {
                        TextField("Filter", text: $profileFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                    }
                }

                if controller.outboundStore.profiles.isEmpty {
                    emptyProfiles
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredProfiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
            }
        }
    }

    private var emptyProfiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No profiles yet")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Paste a vless:// / vmess:// / trojan:// link, or fetch a subscription URL.")
                .font(.system(size: 12))
                .foregroundStyle(Brand.muted)
            HStack(spacing: 8) {
                Button("Import link") { showImport = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.deep)
                Button("Subscription") { showSubscription = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }

    private func profileRow(_ profile: OutboundProfile) -> some View {
        let isActive = controller.outboundConnected && controller.outboundStore.activeProfileId == profile.id
        let isSelected = controller.outboundStore.activeProfileId == profile.id
        let canConnect = controller.outboundBinaryPath != nil && !controller.outboundConnecting

        return HStack(spacing: 12) {
            protocolBadge(profile.protocolLabel)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if isActive {
                        Text("CONNECTED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Brand.success.opacity(0.15)))
                    }
                }
                Text(shortLink(profile.shareLink))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isActive {
                Button("Disconnect") { controller.disconnectOutbound() }
                    .buttonStyle(.bordered)
                    .tint(Brand.danger)
                    .controlSize(.small)
            } else {
                Button {
                    Task { await controller.connectOutbound(profileId: profile.id) }
                } label: {
                    Text(controller.outboundConnecting && isSelected ? "…" : "Connect")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.deep)
                .controlSize(.small)
                .disabled(!canConnect || controller.isBusy)
            }

            Button {
                controller.removeOutboundProfile(profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Remove profile")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Brand.success.opacity(0.08) : Brand.field)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isActive ? Brand.success.opacity(0.35) : Brand.line, lineWidth: 1)
                )
        )
    }

    // MARK: - Add nodes

    private var addNodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showImport.toggle() }
                } label: {
                    Label(showImport ? "Hide import" : "Import share link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSubscription.toggle() }
                } label: {
                    Label(showSubscription ? "Hide subscription" : "Add subscription", systemImage: "link")
                }
                .buttonStyle(.bordered)
            }

            if showImport {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(
                            title: "Import share link",
                            subtitle: "vless:// · vmess:// · trojan:// — one link or a pasted subscription body"
                        )
                        TextEditor(text: $importDraft)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: 140)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.field))
                        ButtonRow {
                            Button("Import") {
                                controller.importOutboundLinks(importDraft)
                                importDraft = ""
                                showImport = false
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.deep)
                            .disabled(importDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Clear") { importDraft = "" }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if showSubscription {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(
                            title: "Subscription URL",
                            subtitle: "Stored locally on this Mac — treat it as a secret."
                        )
                        TextField("https://…", text: $subURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Display name", text: $subName)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task {
                                await controller.fetchOutboundSubscription(url: subURL, name: subName)
                                showSubscription = false
                            }
                        } label: {
                            Label("Fetch subscription", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.deep)
                        .disabled(subURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isBusy)
                    }
                }
            }
        }
    }

    // MARK: - External

    private var externalSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(
                    title: "External outbound",
                    subtitle: "Connect in V2Box / Clash / Karing. Add its utun to the ignore list so Kerio Split never treats it as Kerio."
                )

                if controller.networkSnapshot.secondaryTuns.isEmpty {
                    Label("No secondary tunnel detected", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.muted)
                } else {
                    Label(
                        "Detected: \(controller.networkSnapshot.secondaryTuns.joined(separator: ", "))",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Brand.success)
                }

                HStack {
                    TextField("utunN to ignore", text: $ignoreDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        controller.addIgnoreInterface(ignoreDraft)
                        ignoreDraft = ""
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(controller.config.options.ignoreInterfaces, id: \.self) { iface in
                    HStack {
                        Text(iface).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button("Remove") { controller.removeIgnoreInterface(iface) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                Button("Refresh network") { controller.probeNetwork() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private func protocolBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Brand.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Brand.primary.opacity(0.12))
            )
    }

    private func shortLink(_ link: String) -> String {
        if link.count <= 52 { return link }
        return String(link.prefix(50)) + "…"
    }
}
