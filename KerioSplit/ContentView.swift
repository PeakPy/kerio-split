import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: TunnelController
    @State private var section: AppSection = .overview
    @State private var routeFilter = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 560)
        .preferredColorScheme(preferredScheme)
        .alert("Disconnect split tunneling?", isPresented: $controller.showDisconnectConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { controller.confirmDisconnect() }
        } message: {
            Text("Kerio VPN stays connected. Only the split routes are removed.")
        }
        .onAppear { controller.onAppear() }
    }

    private var preferredScheme: ColorScheme? {
        switch controller.config.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                ForEach(AppSection.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                }
            } header: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Brand.heroGradient)
                            .frame(width: 34, height: 34)
                        Image(nsImage: Brand.logoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Kerio Split")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text("Mehrad")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Brand.deep.opacity(0.85))
                    }
                }
                .padding(.vertical, 4)
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                StatusPill(
                    text: controller.helperReady ? "Helper ready" : "Helper needed",
                    active: controller.helperReady
                )
                StatusPill(
                    text: controller.isActive ? "Split active" : "Split idle",
                    active: controller.isActive
                )
            }
            .padding(12)
            .background(Brand.sidebar)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .overview:
            overviewPage
        case .vpnRoutes:
            routesPage(
                title: "VPN Routes",
                subtitle: "Traffic for these destinations goes through Kerio.",
                routes: controller.config.vpnRoutes,
                draft: $controller.newVpnRoute,
                onAdd: { controller.addVpnRoute() },
                onRemove: { controller.removeVpnRoute($0) }
            )
        case .bypass:
            routesPage(
                title: "Bypass (LAN)",
                subtitle: "These destinations always use your normal gateway.",
                routes: controller.config.bypassRoutes,
                draft: $controller.newBypassRoute,
                onAdd: { controller.addBypassRoute() },
                onRemove: { controller.removeBypassRoute($0) }
            )
        case .settings:
            settingsPage
        case .json:
            jsonPage
        case .activity:
            activityPage
        }
    }

    // MARK: - Overview

    private var overviewPage: some View {
        OverviewDashboard(controller: controller) { destination in
            section = destination
        }
    }

    // MARK: - Routes

    private func routesPage(
        title: String,
        subtitle: String,
        routes: [String],
        draft: Binding<String>,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        let filtered = routeFilter.isEmpty
            ? routes
            : routes.filter { $0.localizedCaseInsensitiveContains(routeFilter) }

        return PageSplit {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: title, subtitle: subtitle)
                    AddRouteField(placeholder: "192.168.70.0/24 or 10.0.0.5", text: draft, onAdd: onAdd)
                    if let err = controller.inputError {
                        Text(err)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if routes.count > 8 {
                        TextField("Filter routes", text: $routeFilter)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .rounded))
                            .frame(maxWidth: 280)
                    }
                }
            }
        } bottom: {
            SurfaceCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(filtered.count) of \(routes.count) entries")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.deep)
                        Spacer(minLength: 8)
                        Button("Save") { controller.saveConfig() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.primary)
                            .controlSize(.small)
                    }

                    if routes.isEmpty {
                        Text("No routes yet. Add a host or CIDR above.")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                    } else if filtered.isEmpty {
                        Text("No matches for “\(routeFilter)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    } else {
                        List {
                            ForEach(filtered, id: \.self) { route in
                                RouteRow(route: route) { onRemove(route) }
                                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            controller.inputError = nil
            routeFilter = ""
        }
    }

    // MARK: - Settings

    private var settingsPage: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                SurfaceCard {
                    AppearancePicker(
                        mode: Binding(
                            get: { controller.config.appearance },
                            set: { controller.setAppearance($0) }
                        )
                    )
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(title: "Tunnel behavior", subtitle: "Changes save immediately to config.json.")
                            .padding(.bottom, 8)

                        SettingsToggle(
                            title: "Remove Kerio full-tunnel",
                            subtitle: "Delete 0/1 and 128.0/1 hijack routes when applying split.",
                            isOn: Binding(
                                get: { controller.config.options.removeFullTunnel },
                                set: { controller.config.options.removeFullTunnel = $0; controller.saveConfig() }
                            )
                        )
                        Divider()
                        SettingsToggle(
                            title: "Restore LAN default gateway",
                            subtitle: "Keep internet on Wi‑Fi/Ethernet while Kerio stays connected.",
                            isOn: Binding(
                                get: { controller.config.options.restoreLanDefault },
                                set: { controller.config.options.restoreLanDefault = $0; controller.saveConfig() }
                            )
                        )
                        Divider()
                        SettingsToggle(
                            title: "Restore LAN DNS",
                            subtitle: "Strip Kerio-pushed resolvers so public DNS works again.",
                            isOn: Binding(
                                get: { controller.config.options.restoreLanDns },
                                set: { controller.config.options.restoreLanDns = $0; controller.saveConfig() }
                            )
                        )
                        Divider()
                        SettingsToggle(
                            title: "Auto-apply on launch",
                            subtitle: "Apply split automatically when the app opens (helper required).",
                            isOn: Binding(
                                get: { controller.config.options.autoApplyOnLaunch },
                                set: { controller.config.options.autoApplyOnLaunch = $0; controller.saveConfig() }
                            )
                        )
                        Divider()
                        SettingsToggle(
                            title: "Confirm before disconnect",
                            subtitle: "Ask once before tearing down split routes.",
                            isOn: Binding(
                                get: { controller.config.options.confirmBeforeDisconnect },
                                set: { controller.config.options.confirmBeforeDisconnect = $0; controller.saveConfig() }
                            )
                        )
                        Divider()
                        SettingsToggle(
                            title: "Launch at login",
                            subtitle: "Open Kerio Split when you log in to this Mac.",
                            isOn: Binding(
                                get: { controller.config.options.launchAtLogin },
                                set: { controller.setLaunchAtLogin($0) }
                            )
                        )
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Custom DNS", subtitle: "Optional. Applied while split is ON.")
                        AddRouteField(placeholder: "178.22.122.101", text: $controller.newDns, onAdd: { controller.addDns() })
                        if let err = controller.inputError {
                            Text(err)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Brand.danger)
                        }
                        ForEach(controller.config.options.customDns, id: \.self) { dns in
                            RouteRow(route: dns) { controller.removeDns(dns) }
                        }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Config file")
                        Text(controller.configPathDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Brand.muted)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        WrappingHStack(spacing: 8) {
                            Button("Reveal in Finder") { controller.revealConfigInFinder() }
                            Button("Copy path") { controller.copyConfigPath() }
                            Button("Export…") { controller.exportConfig() }
                            Button("Import…") { controller.importConfig() }
                            Button("Reload") { controller.reloadFromDisk() }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(title: "About")
                        Text("Kerio Split \(controller.appVersion)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                        Text("Mehrad Technical Team · Split tunneling for Kerio Control VPN Client")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { controller.inputError = nil }
    }

    // MARK: - JSON

    private var jsonPage: some View {
        PageSplit {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(
                        title: "config.json",
                        subtitle: "Edit JSON directly. Apply writes the file and updates the UI."
                    )
                    WrappingHStack(spacing: 8) {
                        Button("Reload from disk") { controller.reloadFromDisk() }
                            .buttonStyle(.bordered)
                        Button("Format from UI") { controller.saveConfig() }
                            .buttonStyle(.bordered)
                        Button("Apply JSON → UI + disk") { controller.applyJsonEditor() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.deep)
                    }
                    .disabled(controller.isBusy)

                    if let err = controller.jsonError {
                        Text(err)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } bottom: {
            SurfaceCard(padding: 0) {
                TextEditor(text: $controller.jsonText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Brand.ink)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Activity

    private var activityPage: some View {
        PageSplit {
            SurfaceCard {
                HStack(alignment: .top, spacing: 12) {
                    SectionLabel(title: "Activity log", subtitle: "Engine output and helper messages.")
                    Spacer(minLength: 8)
                    Button("Clear") { controller.clearLog() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(controller.log.isEmpty)
                }
            }
        } bottom: {
            SurfaceCard(padding: 12) {
                ScrollView {
                    Text(controller.log.isEmpty ? "No activity yet." : controller.log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Brand.ink.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
