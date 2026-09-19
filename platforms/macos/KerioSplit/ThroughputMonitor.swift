import Foundation
import SwiftUI

/// One live throughput series for a network interface (Kerio utun, outbound, LAN, …).
struct ThroughputSeries: Identifiable {
    let id: String
    var title: String
    var iface: String
    var accent: Color
    var downBps: Double = 0
    var upBps: Double = 0
    var downHistory: [Double] = []
    var upHistory: [Double] = []

    var downText: String { Self.formatRate(downBps) }
    var upText: String { Self.formatRate(upBps) }
    var totalText: String { Self.formatRate(downBps + upBps) }

    static func formatRate(_ bps: Double) -> String {
        let v = max(0, bps)
        if v < 10 { return "0 B/s" }
        if v < 1024 { return String(format: "%.0f B/s", v) }
        if v < 1_048_576 { return String(format: "%.1f KB/s", v / 1024) }
        if v < 1_073_741_824 { return String(format: "%.2f MB/s", v / 1_048_576) }
        return String(format: "%.2f GB/s", v / 1_073_741_824)
    }
}

/// Samples `netstat -ib` counters and derives live up/down rates per interface.
@MainActor
final class ThroughputMonitor: ObservableObject {
    @Published private(set) var series: [ThroughputSeries] = []

    private var timer: Timer?
    private var lastBytes: [String: (inB: UInt64, outB: UInt64, at: Date)] = [:]
    private let historyLimit = 60
    /// Ignore sub-noise rates so sparklines stay flat when idle.
    private let noiseFloor: Double = 64
    private var tracked: [(id: String, title: String, iface: String, accent: Color)] = []

    func start(tracking: [(id: String, title: String, iface: String, accent: Color)]) {
        let next = tracking.filter { !$0.iface.isEmpty }
        let prevIfaces = Set(tracked.map(\.iface))
        let nextIfaces = Set(next.map(\.iface))
        tracked = next

        // Drop stale counter baselines when iface set changes
        for gone in prevIfaces.subtracting(nextIfaces) {
            lastBytes.removeValue(forKey: gone)
        }

        if timer == nil {
            refresh()
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            let keep = Set(tracked.map(\.id))
            series.removeAll { !keep.contains($0.id) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastBytes.removeAll()
        series = []
        tracked = []
    }

    private func refresh() {
        let targets = tracked
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let counters = Self.readInterfaceBytes()
            let now = Date()
            DispatchQueue.main.async {
                guard let self else { return }
                var next: [ThroughputSeries] = []
                for t in targets {
                    var item = self.series.first(where: { $0.id == t.id })
                        ?? ThroughputSeries(id: t.id, title: t.title, iface: t.iface, accent: t.accent)
                    item.title = t.title
                    item.iface = t.iface
                    item.accent = t.accent

                    guard let bytes = counters[t.iface] else {
                        item.downBps = 0
                        item.upBps = 0
                        self.appendSample(&item, down: 0, up: 0)
                        next.append(item)
                        continue
                    }

                    if let prev = self.lastBytes[t.iface] {
                        let dt = now.timeIntervalSince(prev.at)
                        // Skip jittery / too-fast ticks
                        if dt >= 0.75 {
                            // Use saturating subtract — never wrap on counter reset
                            let dinRaw = bytes.inB >= prev.inB ? bytes.inB - prev.inB : 0
                            let doutRaw = bytes.outB >= prev.outB ? bytes.outB - prev.outB : 0
                            var din = Double(dinRaw) / dt
                            var dout = Double(doutRaw) / dt
                            if din < self.noiseFloor { din = 0 }
                            if dout < self.noiseFloor { dout = 0 }
                            // Cap absurd spikes (iface recreate mid-sample)
                            if din > 500_000_000 { din = item.downBps }
                            if dout > 500_000_000 { dout = item.upBps }
                            // EMA smooth — professional chart feel without lagging hard
                            let alpha = 0.45
                            din = item.downBps * (1 - alpha) + din * alpha
                            dout = item.upBps * (1 - alpha) + dout * alpha
                            if din < self.noiseFloor { din = 0 }
                            if dout < self.noiseFloor { dout = 0 }
                            item.downBps = din
                            item.upBps = dout
                            self.appendSample(&item, down: din, up: dout)
                            self.lastBytes[t.iface] = (bytes.inB, bytes.outB, now)
                        }
                    } else {
                        // First sample — establish baseline only
                        self.lastBytes[t.iface] = (bytes.inB, bytes.outB, now)
                    }
                    next.append(item)
                }
                self.series = next
            }
        }
    }

    private func appendSample(_ item: inout ThroughputSeries, down: Double, up: Double) {
        item.downHistory.append(down)
        item.upHistory.append(up)
        if item.downHistory.count > historyLimit {
            item.downHistory.removeFirst(item.downHistory.count - historyLimit)
            item.upHistory.removeFirst(item.upHistory.count - historyLimit)
        }
    }

    /// Parse Link-layer rows from `netstat -ib -n`. Address column is optional (utun has none).
    nonisolated static func readInterfaceBytes() -> [String: (inB: UInt64, outB: UInt64)] {
        let result = HelperService.runProcess("/usr/sbin/netstat", ["-ib", "-n"], timeoutSeconds: 3)
        guard result.ok else { return [:] }
        var map: [String: (inB: UInt64, outB: UInt64)] = [:]
        for line in result.text.split(separator: "\n") {
            guard let parsed = parseLinkRow(String(line)) else { continue }
            // Prefer first Link row per iface
            if map[parsed.name] == nil {
                map[parsed.name] = (parsed.inB, parsed.outB)
            }
        }
        return map
    }

    /// Unit-testable Link-row parser.
    nonisolated static func parseLinkRow(_ line: String) -> (name: String, inB: UInt64, outB: UInt64)? {
        let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard cols.count >= 8, cols[0] != "Name" else { return nil }
        guard let linkIdx = cols.firstIndex(where: { $0.hasPrefix("<Link") }) else { return nil }

        // After <Link#N>: optional MAC (contains ':'), then Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
        var i = linkIdx + 1
        if i < cols.count, cols[i].contains(":") {
            i += 1
        }
        // Need Ipkts Ierrs Ibytes Opkts Oerrs Obytes
        guard i + 5 < cols.count,
              let ibytes = UInt64(cols[i + 2]),
              let obytes = UInt64(cols[i + 5]) else { return nil }
        return (cols[0], ibytes, obytes)
    }
}

// MARK: - Sparkline

struct ThroughputSparkline: View {
    let down: [Double]
    let up: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let peak = max(down.max() ?? 0, up.max() ?? 0)
            ZStack(alignment: .bottomLeading) {
                if peak < 1 || (down.count < 2 && up.count < 2) {
                    // Idle baseline
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h * 0.82))
                        path.addLine(to: CGPoint(x: w, y: h * 0.82))
                    }
                    .stroke(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    Path { path in
                        guard down.count > 1 else { return }
                        path.move(to: CGPoint(x: 0, y: h))
                        for (i, v) in down.enumerated() {
                            let x = w * CGFloat(i) / CGFloat(down.count - 1)
                            let y = h - (CGFloat(v / peak) * h * 0.88)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(accent.opacity(0.14))

                    Path { path in
                        addLine(&path, values: down, width: w, height: h, peak: peak)
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

                    Path { path in
                        addLine(&path, values: up, width: w, height: h, peak: peak)
                    }
                    .stroke(Brand.warn.opacity(0.95), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func addLine(_ path: inout Path, values: [Double], width: CGFloat, height: CGFloat, peak: Double) {
        guard values.count > 1, peak > 0 else { return }
        for (i, v) in values.enumerated() {
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let y = height - (CGFloat(v / peak) * height * 0.88)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
}

struct ThroughputCard: View {
    let series: ThroughputSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                    Text(series.iface)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(series.totalText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(series.accent)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            ThroughputSparkline(down: series.downHistory, up: series.upHistory, accent: series.accent)
                .frame(minHeight: 64, idealHeight: 72)
                .frame(maxWidth: .infinity)

            HStack(spacing: 16) {
                rateLabel(icon: "arrow.down", text: series.downText, color: series.accent)
                rateLabel(icon: "arrow.up", text: series.upText, color: Brand.warn)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(series.accent.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private func rateLabel(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.ink.opacity(0.8))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
