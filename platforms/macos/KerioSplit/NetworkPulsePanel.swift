import SwiftUI

/// Unified Overview panel: live rates + topology map in one composition.
struct NetworkPulsePanel: View {
    let snapshot: NetworkSnapshot
    let splitActive: Bool
    let outboundConnected: Bool
    let series: [ThroughputSeries]
    var onRefresh: () -> Void

    @State private var pulse = false

    private var totalBps: Double {
        series.reduce(0) { $0 + $1.downBps + $1.upBps }
    }

    var body: some View {
        SurfaceCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.4)

                // Rate ribbon — sits above the map as one visual system
                rateRibbon
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                // Map shares the same card — no second title/card
                VPNTopologyView(
                    snapshot: snapshot,
                    splitActive: splitActive,
                    outboundConnected: outboundConnected,
                    onRefresh: onRefresh,
                    embedded: true
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Network")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if totalBps > 0 {
                Text(ThroughputSeries.formatRate(totalBps))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.primary)
                    .monospacedDigit()
            }

            liveBadge

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh network")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        let connected = snapshot.connectedVPNCount + (outboundConnected ? 1 : 0)
        if series.isEmpty {
            return connected > 0 ? "\(connected) path(s) · waiting for counters" : "Map + live rates"
        }
        if connected > 0 {
            return "\(connected) connected · rates every 1s"
        }
        return "Live rates · topology"
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

    @ViewBuilder
    private var rateRibbon: some View {
        if series.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Brand.primary.opacity(0.7))
                Text("Rates appear when Kerio, outbound, or LAN interfaces are up.")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.field.opacity(0.7))
            )
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(series) { s in
                        RatePill(series: s)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(series) { s in
                            RatePill(series: s)
                                .frame(width: 200)
                        }
                    }
                }
            }
        }
    }
}

/// Compact rate + mini sparkline — designed to sit inside NetworkPulsePanel.
private struct RatePill: View {
    let series: ThroughputSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(series.accent)
                    .frame(width: 7, height: 7)
                Text(series.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(series.totalText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(series.accent)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            ThroughputSparkline(down: series.downHistory, up: series.upHistory, accent: series.accent)
                .frame(height: 36)

            HStack(spacing: 12) {
                Label {
                    Text(series.downText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(series.accent)
                }
                Label {
                    Text(series.upText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Brand.warn)
                }
                Spacer(minLength: 0)
                Text(series.iface)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
            .foregroundStyle(Brand.ink.opacity(0.75))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.field)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(series.accent.opacity(0.28), lineWidth: 1)
                )
        )
    }
}
