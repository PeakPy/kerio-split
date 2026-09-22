import SwiftUI

/// Full-page Activity + diagnostics (replaces the cramped PageSplit layout).
struct ActivityDashboard: View {
    @ObservedObject var controller: TunnelController

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                diagnosisCard
                snapshotCard
                eventsCard
                engineLogCard
            }
        }
        .onAppear {
            controller.refreshDiagnostics()
            controller.probeNetwork()
        }
    }

    private var diagnosisCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    SectionLabel(
                        title: "Diagnostics",
                        subtitle: controller.diagnosticReport.summary.isEmpty
                            ? "Live checklist — what works and what is blocking you."
                            : controller.diagnosticReport.summary
                    )
                    Spacer(minLength: 8)
                    Button("Re-scan") {
                        controller.refreshDiagnostics()
                        controller.probeNetwork()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Copy report") {
                        controller.copyDiagnostics()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("If something looks wrong, Copy flight log and paste it in chat — it includes connect clicks, network flips, and Kerio state.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Brand.deep)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(FlightRecorder.filePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                        .textSelection(.enabled)
                    ButtonRow {
                        Button("Copy flight log") { controller.copyFlightLog() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.deep)
                        Button("Reveal log file") { controller.revealFlightLog() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.primary.opacity(0.08))
                )

                if !controller.diagnosticReport.suggestedFix.isEmpty {
                    Text(controller.diagnosticReport.suggestedFix)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.deep)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Brand.primary.opacity(0.10))
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.diagnosticReport.items) { item in
                        diagnosticRow(item)
                    }
                }

                ButtonRow {
                    ForEach(controller.scenario.actions.prefix(3)) { action in
                        Button(action.title) {
                            controller.performScenarioAction(action)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.deep)
                    }
                }
                .disabled(controller.isBusy)
            }
        }
    }

    private func diagnosticRow(_ item: DiagnosticItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor(item.status))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: DiagnosticItem.Status) -> Color {
        switch status {
        case .ok: return Brand.success
        case .warn: return Brand.warn
        case .fail: return Brand.danger
        case .info: return Brand.primary
        }
    }

    private var snapshotCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Network snapshot", subtitle: "Raw sense of the Mac right now.")
                gridRow("Kerio session", controller.networkSnapshot.kerioSessionConnected
                    ? "Connected · \(controller.networkSnapshot.kerioSessionLabel)"
                    : "Disconnected")
                gridRow("Daemon", controller.networkSnapshot.kerioDaemonRunning ? "kvpncsvc running" : "kvpncsvc not running")
                gridRow("Tunnel", {
                    let s = controller.networkSnapshot
                    if s.kerioInterface.isEmpty { return "none" }
                    return "\(s.kerioInterface) · \(s.kerioTunnelAddress.isEmpty ? "?" : s.kerioTunnelAddress) · gw \(s.kerioGateway.isEmpty ? "?" : s.kerioGateway)"
                }())
                gridRow("Default", "\(controller.networkSnapshot.defaultInterface) via \(controller.networkSnapshot.defaultGateway)")
                gridRow("Hijack 0/1", controller.networkSnapshot.fullTunnelHijack ? "yes" : "no")
                gridRow("VPN routes present", controller.networkSnapshot.managedRoutesPresent.isEmpty
                    ? "—"
                    : controller.networkSnapshot.managedRoutesPresent.joined(separator: ", "))
                gridRow("Other tuns", controller.networkSnapshot.secondaryTuns.isEmpty
                    ? "—"
                    : controller.networkSnapshot.secondaryTuns.joined(separator: ", "))
                gridRow("DNS", controller.networkSnapshot.dnsServers.prefix(3).joined(separator: ", ").nilIfEmpty ?? "—")
                gridRow("Connectivity", controller.connectivity.detail.nilIfEmpty ?? "—")
                if !controller.networkSnapshot.tunnelEvidence.isEmpty {
                    gridRow("Evidence", controller.networkSnapshot.tunnelEvidence.joined(separator: " · "))
                }
            }
        }
    }

    private func gridRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.muted)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Brand.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var eventsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(title: "Timeline", subtitle: "What changed — sense, guard, outbound, connect.")
                    Spacer()
                    Button("Clear") { controller.clearLog() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(controller.networkEvents.isEmpty && controller.log.isEmpty)
                }
                if controller.networkEvents.isEmpty {
                    Text("No events yet. Connect All, Repair, or Re-scan to generate history.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.muted)
                } else {
                    ForEach(controller.networkEvents.prefix(40)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Text(event.at.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Brand.muted)
                                .frame(width: 72, alignment: .leading)
                            Text(event.message)
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    private var engineLogCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Engine log", subtitle: "Raw output from apply / restore / guard / helper.")
                ScrollView {
                    Text(controller.log.isEmpty ? "No engine output yet." : controller.log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Brand.ink.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 160, maxHeight: 280)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.field)
                )
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
