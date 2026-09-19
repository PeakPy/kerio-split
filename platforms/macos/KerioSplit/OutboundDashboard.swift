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
    @State private var showAdvanced = false
    @State private var profileFilter = ""
    @State private var tick = Date()

    private var mode: OutboundMode { controller.config.options.outboundMode }
    private var activeProfile: OutboundProfile? {
        guard let id = controller.outboundStore.activeProfileId else { return nil }
        return controller.outboundStore.profiles.first { $0.id == id }
    }

    private var filteredProfiles: [OutboundProfile] {
        let q = profileFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = controller.outboundStore.profiles
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.protocolLabel.lowercased().contains(q)
            }
        }
        // Sort by latency when available (unreachable last)
        return list.sorted { a, b in
            let la = controller.outboundLatencies[a.id]
            let lb = controller.outboundLatencies[b.id]
            switch (la, lb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    private var outboundIface: String {
        let snap = controller.networkSnapshot
        if !snap.outboundInterface.isEmpty { return snap.outboundInterface }
        if let t = snap.secondaryTuns.first(where: { $0 != snap.kerioInterface }) { return t }
        return ""
    }

    private var bestLatencyId: String? {
        controller.outboundLatencies.min(by: { $0.value < $1.value })?.key
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                connectionHero
                modePicker

                if mode == .builtIn {
                    if controller.outboundBinaryPath == nil || controller.outboundEngineBusy {
                        engineCard
                    }
                    if controller.outboundConnected || !outboundIface.isEmpty {
                        liveStrip
                        liveTrafficSection
                    }
                    profilesCard
                    addNodesSection
                    advancedDetails
                } else if mode == .external {
                    externalSection
                    advancedDetails
                } else {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Outbound is off")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text("Kerio Split only manages corporate CIDRs. Switch to Built-in when you want a second tunnel for general internet.")
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
        .onChange(of: controller.networkSnapshot.outboundInterface) { _ in syncThroughput() }
        .onChange(of: controller.networkSnapshot.secondaryTuns) { _ in syncThroughput() }
        .onChange(of: controller.networkSnapshot.defaultInterface) { _ in syncThroughput() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            tick = date
        }
    }

    private func syncThroughput() {
        var targets: [(id: String, title: String, iface: String, accent: Color)] = []
        // Outbound page: only profile tunnel (+ LAN path). No Kerio card here.
        if !outboundIface.isEmpty {
            let title = controller.outboundActiveName.isEmpty ? "Outbound" : controller.outboundActiveName
            targets.append((id: "outbound", title: title, iface: outboundIface, accent: Brand.warn))
        }
        let snap = controller.networkSnapshot
        if !snap.lanInterface.isEmpty {
            targets.append((id: "lan", title: "LAN", iface: snap.lanInterface, accent: Brand.primarySoft))
        }
        throughput.start(tracking: Array(targets.prefix(2)))
    }

    // MARK: - Hero

    private var connectionHero: some View {
        let connected = controller.outboundConnected
        let connecting = controller.outboundConnecting || controller.outboundAutoSelecting
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
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.22), accent.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)
                        Image(systemName: connecting
                              ? "arrow.triangle.2.circlepath"
                              : (connected ? "checkmark.shield.fill" : "shield.lefthalf.filled"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(heroTitle)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text(heroSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let err = controller.outboundError, !err.isEmpty, !connected {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.danger)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    if connected || controller.outboundConnecting {
                        Button {
                            controller.disconnectOutbound()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.danger)
                        .disabled(controller.outboundConnecting)
                    } else if mode == .builtIn, !controller.outboundStore.profiles.isEmpty {
                        Button {
                            Task { await controller.autoSelectOutbound() }
                        } label: {
                            Label(
                                controller.outboundAutoSelecting ? "Selecting…" : "Auto-select",
                                systemImage: "bolt.horizontal.circle.fill"
                            )
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.deep)
                        .disabled(controller.outboundBinaryPath == nil || controller.isBusy || controller.outboundPinging)
                    }
                }
                .padding(20)

                if connected {
                    Divider().opacity(0.4)
                    HStack(spacing: 10) {
                        if let p = activeProfile {
                            protocolBadge(p.protocolLabel)
                            Text(p.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            if let ms = controller.outboundLatencies[p.id] {
                                latencyPill(ms, emphasize: true)
                            }
                        } else if !controller.outboundActiveName.isEmpty {
                            Text(controller.outboundActiveName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        Text(durationText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Brand.muted)
                            .monospacedDigit()
                        if !outboundIface.isEmpty {
                            Text(outboundIface)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Live strip (compact)

    private var liveStrip: some View {
        let series = throughput.series.first { $0.id == "outbound" }
        return SurfaceCard {
            HStack(spacing: 0) {
                liveMetric("Speed", series?.totalMbpsText ?? "—")
                Divider().frame(height: 28)
                liveMetric("Down", series?.downText ?? "—")
                Divider().frame(height: 28)
                liveMetric("Up", series?.upText ?? "—")
                Divider().frame(height: 28)
                liveMetric("Tunnel", outboundIface.isEmpty ? "—" : outboundIface)
                Divider().frame(height: 28)
                liveMetric("Split", controller.isActive ? "ON" : "OFF")
            }
        }
    }

    private func liveMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var liveTrafficSection: some View {
        Group {
            if !throughput.series.isEmpty {
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
                Image(systemName: "shippingbox")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Brand.warn)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Engine needed")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(controller.outboundEngineBusy
                         ? (controller.outboundEngineProgress.isEmpty ? "Downloading…" : controller.outboundEngineProgress)
                         : "One tap installs sing-box. Route helper is required for TUN.")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if controller.outboundEngineBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await controller.installOutboundEngine() }
                    } label: {
                        Label("Install engine", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.deep)
                }
            }
        }
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(
                        title: "Profiles",
                        subtitle: controller.outboundStore.profiles.isEmpty
                            ? "Import a share link or subscription"
                            : "\(controller.outboundStore.profiles.count) saved"
                    )
                    Spacer()
                    if !controller.outboundStore.profiles.isEmpty {
                        TextField("Filter", text: $profileFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                    }
                }

                if !controller.outboundStore.profiles.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            Task { await controller.pingOutboundProfiles() }
                        } label: {
                            Label(
                                controller.outboundPinging ? "Pinging…" : "Ping all",
                                systemImage: "waveform.path.ecg"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(controller.outboundPinging || controller.outboundConnecting || controller.isBusy)

                        Button {
                            Task { await controller.autoSelectOutbound() }
                        } label: {
                            Label(
                                controller.outboundAutoSelecting ? "Selecting…" : "Auto-select best",
                                systemImage: "bolt.horizontal.circle"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.deep)
                        .disabled(
                            controller.outboundBinaryPath == nil
                                || controller.outboundPinging
                                || controller.outboundConnecting
                                || controller.outboundAutoSelecting
                                || controller.isBusy
                        )

                        Spacer()

                        if !controller.outboundLatencies.isEmpty {
                            Text("\(controller.outboundLatencies.count) reachable")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Brand.muted)
                        }
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
        let latency = controller.outboundLatencies[profile.id]
        let isBest = bestLatencyId == profile.id && latency != nil

        return HStack(spacing: 12) {
            protocolBadge(profile.protocolLabel)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if isActive {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Brand.success.opacity(0.15)))
                    } else if isBest {
                        Text("BEST")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.deep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Brand.deep.opacity(0.12)))
                    }
                }
                if let ep = profile.endpointHostPort {
                    Text("\(ep.host):\(ep.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if controller.outboundPinging && latency == nil {
                ProgressView().controlSize(.mini)
            } else if let ms = latency {
                latencyPill(ms, emphasize: isBest)
            } else if !controller.outboundLatencies.isEmpty {
                Text("timeout")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Brand.danger.opacity(0.85))
            }

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
                .disabled(!canConnect || controller.isBusy || controller.outboundAutoSelecting)
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
                        .strokeBorder(
                            isActive ? Brand.success.opacity(0.35) : (isBest ? Brand.deep.opacity(0.35) : Brand.line),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Advanced (collapsed)

    private var advancedDetails: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                detailRow("Outbound status", controller.outboundStatusDetail)
                detailRow("Active profile", controller.outboundActiveName.isEmpty ? (activeProfile?.name ?? "None") : controller.outboundActiveName)
                detailRow("Outbound iface", outboundIface.isEmpty ? "Not detected" : outboundIface)
                detailRow(
                    "Default route",
                    "\(controller.networkSnapshot.defaultInterface.isEmpty ? "?" : controller.networkSnapshot.defaultInterface) via \(controller.networkSnapshot.defaultGateway.isEmpty ? "link" : controller.networkSnapshot.defaultGateway)"
                )
                detailRow(
                    "Kerio",
                    controller.networkSnapshot.kerioInterface.isEmpty
                        ? (controller.networkSnapshot.kerioSessionConnected ? "Session up · no utun yet" : "No Kerio tunnel")
                        : "\(controller.networkSnapshot.kerioInterface) · gw \(controller.networkSnapshot.kerioGateway)"
                )
                detailRow("Ignore list", controller.config.options.ignoreInterfaces.isEmpty ? "Empty" : controller.config.options.ignoreInterfaces.joined(separator: ", "))
                if let path = controller.outboundBinaryPath {
                    detailRow("Engine", path)
                }
                HStack(spacing: 8) {
                    Button("Refresh network") {
                        controller.probeNetwork()
                        syncThroughput()
                    }
                    .buttonStyle(.bordered)
                    if controller.outboundBinaryPath != nil {
                        Button("Reinstall engine") {
                            Task { await controller.installOutboundEngine() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Connection details")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.ink)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Brand.line, lineWidth: 1)
                )
        )
        .id(tick.timeIntervalSince1970.rounded())
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
                            subtitle: "vless:// · vmess:// · trojan://"
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

    private var heroTitle: String {
        if controller.outboundAutoSelecting { return "Auto-selecting…" }
        if controller.outboundConnecting { return "Connecting…" }
        if controller.outboundConnected { return "Connected" }
        if mode == .off { return "Outbound off" }
        if mode == .external { return "External mode" }
        return "Ready to connect"
    }

    private var heroSubtitle: String {
        if controller.outboundAutoSelecting || controller.outboundConnecting {
            return controller.outboundStatusDetail
        }
        if controller.outboundConnected {
            return controller.outboundStatusDetail.isEmpty
                ? "General internet uses outbound. Kerio CIDRs stay on Kerio."
                : controller.outboundStatusDetail
        }
        if mode == .builtIn {
            return "Ping profiles, auto-select the fastest, or connect manually. Kerio routes stay guarded."
        }
        if mode == .external {
            return "Connect in your other VPN app. Kerio Split will detect its tunnel."
        }
        return "Enable Built-in or External to add a second tunnel for general internet."
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

    private func latencyPill(_ ms: Int, emphasize: Bool) -> some View {
        let color: Color = {
            if ms < 120 { return Brand.success }
            if ms < 250 { return Brand.warn }
            return Brand.danger
        }()
        return Text("\(ms) ms")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(emphasize ? .white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(emphasize ? color : color.opacity(0.14))
            )
            .monospacedDigit()
    }
}
