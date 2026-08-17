import SwiftUI

// MARK: - Layout primitives

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(22)
                .frame(maxWidth: 860, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        // Critical on macOS NavigationSplitView: without this, detail can collapse to empty.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.softGradient.ignoresSafeArea())
    }
}

/// Fills the detail pane; top is fixed, bottom scrolls or expands.
struct PageSplit<Top: View, Bottom: View>: View {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        VStack(spacing: 0) {
            top()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            bottom()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.softGradient.ignoresSafeArea())
    }
}

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Brand.line, lineWidth: 1)
            )
            .shadow(color: Brand.deep.opacity(0.05), radius: 10, y: 3)
    }
}

struct SectionLabel: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var destructive: Bool = false
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    Text("Working…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                } else {
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(destructive ? AnyShapeStyle(Brand.danger) : AnyShapeStyle(Brand.heroGradient))
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.85 : 1)
    }
}

struct StatusPill: View {
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(active ? Brand.success : Brand.primary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Brand.ink.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Brand.field)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Brand.line, lineWidth: 1)
                )
        )
    }
}

struct RouteRow: View {
    let route: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.grid.cross")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Brand.primary.opacity(0.12)))

            Text(route)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.danger.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.field)
        )
    }
}

struct AddRouteField: View {
    let placeholder: String
    @Binding var text: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Brand.field)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Brand.line, lineWidth: 1)
                        )
                )
                .onSubmit(onAdd)

            Button(action: onAdd) {
                Text("Add")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Brand.primary)
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
    }
}

struct AppearancePicker: View {
    @Binding var mode: AppearanceMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(
                title: "Appearance",
                subtitle: "Follow macOS Light/Dark, or lock the app to one mode."
            )
            Picker("Appearance", selection: $mode) {
                ForEach(AppearanceMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
        }
    }
}

enum SessionPhase: String, Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
}

enum FlowStepState: String, Equatable {
    case pending
    case running
    case done
    case failed
    case skipped

    var isLit: Bool {
        self == .running || self == .done
    }
}

struct FlowStep: Identifiable, Equatable {
    let id: String
    var title: String
    var detail: String
    var state: FlowStepState
}

struct ProcessTimeline: View {
    let steps: [FlowStep]
    var phase: SessionPhase = .idle

    private var progress: CGFloat {
        guard !steps.isEmpty else { return 0 }
        let weight: CGFloat = steps.reduce(0) { sum, step in
            switch step.state {
            case .done, .skipped: return sum + 1
            case .running: return sum + 0.55
            case .failed: return sum + 0.35
            case .pending: return sum
            }
        }
        return min(1, weight / CGFloat(steps.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            progressRail
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, index: index)
                }
            }
        }
        .animation(.spring(response: 0.44, dampingFraction: 0.86), value: steps)
        .animation(.spring(response: 0.44, dampingFraction: 0.86), value: phase)
    }

    private var progressRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Brand.line)
                        .frame(height: 6)
                    Capsule()
                        .fill(railGradient)
                        .frame(width: max(6, geo.size.width * progress), height: 6)
                }
            }
            .frame(height: 6)

            HStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { _, step in
                    VStack(spacing: 6) {
                        railDot(step.state)
                        Text(step.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(step.state == .pending ? Brand.muted : Brand.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var railGradient: LinearGradient {
        switch phase {
        case .disconnecting:
            return LinearGradient(colors: [Brand.danger, Brand.deep], startPoint: .leading, endPoint: .trailing)
        case .connected:
            return LinearGradient(colors: [Brand.success, Brand.primary], startPoint: .leading, endPoint: .trailing)
        default:
            return Brand.heroGradient
        }
    }

    private func railDot(_ state: FlowStepState) -> some View {
        ZStack {
            Circle()
                .fill(glyphFill(state))
                .frame(width: 10, height: 10)
            if state == .running {
                Circle()
                    .stroke(Brand.primary.opacity(0.55), lineWidth: 2)
                    .frame(width: 16, height: 16)
                    .modifier(SoftPulseRing())
            }
        }
        .frame(width: 16, height: 16)
    }

    private func stepRow(_ step: FlowStep, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                stepGlyph(step)
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(connectorColor(step.state))
                        .frame(width: 2, height: 22)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(step.state == .pending ? Brand.muted : Brand.ink)
                Text(step.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(step.state == .failed ? Brand.danger : Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, index < steps.count - 1 ? 10 : 0)
            .opacity(step.state == .pending ? 0.72 : 1)
        }
    }

    private func connectorColor(_ state: FlowStepState) -> Color {
        switch state {
        case .done, .skipped: return Brand.primary.opacity(0.45)
        case .running: return Brand.primary.opacity(0.28)
        case .failed: return Brand.danger.opacity(0.45)
        case .pending: return Brand.line
        }
    }

    @ViewBuilder
    private func stepGlyph(_ step: FlowStep) -> some View {
        ZStack {
            Circle()
                .fill(glyphFill(step.state))
                .frame(width: 26, height: 26)
            switch step.state {
            case .pending:
                Circle()
                    .strokeBorder(Brand.line, lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                Text("\(steps.firstIndex(where: { $0.id == step.id }).map { $0 + 1 } ?? 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.muted)
            case .running:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            case .skipped:
                Image(systemName: "forward.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Brand.primary)
            }
        }
        .id("\(step.id)-\(step.state.rawValue)")
    }

    private func glyphFill(_ state: FlowStepState) -> Color {
        switch state {
        case .pending: return Brand.field
        case .running: return Brand.primary.opacity(0.16)
        case .done: return Brand.success
        case .failed: return Brand.danger
        case .skipped: return Brand.primary.opacity(0.12)
        }
    }
}

private struct SoftPulseRing: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.55 : 1)
            .opacity(on ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    on = true
                }
            }
    }
}

struct DualActionBar: View {
    enum Style {
        case hero
        case card
    }

    let connectEnabled: Bool
    let disconnectEnabled: Bool
    let connecting: Bool
    let disconnecting: Bool
    var style: Style = .hero
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onConnect) {
                label(
                    title: connecting ? "Connecting…" : "Connect All",
                    icon: connecting ? "hourglass" : "bolt.fill",
                    kind: .connect
                )
            }
            .buttonStyle(.plain)
            .disabled(!connectEnabled)
            .opacity(connectEnabled ? 1 : 0.42)

            Button(action: onDisconnect) {
                label(
                    title: disconnecting ? "Disconnecting…" : "Disconnect All",
                    icon: disconnecting ? "hourglass" : "bolt.slash.fill",
                    kind: .disconnect
                )
            }
            .buttonStyle(.plain)
            .disabled(!disconnectEnabled)
            .opacity(disconnectEnabled ? 1 : 0.42)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: connecting)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: disconnecting)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: connectEnabled)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: disconnectEnabled)
    }

    private enum Kind { case connect, disconnect }

    private func label(title: String, icon: String, kind: Kind) -> some View {
        let active = (kind == .connect && connecting) || (kind == .disconnect && disconnecting)
        return HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground(kind))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            Capsule(style: .continuous)
                .fill(fill(kind))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(stroke(kind), lineWidth: 1)
        )
        .scaleEffect(active ? 0.98 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: active)
    }

    private func foreground(_ kind: Kind) -> Color {
        switch (style, kind) {
        case (.hero, .connect): return Brand.deep
        case (.hero, .disconnect): return .white
        case (.card, .connect): return .white
        case (.card, .disconnect): return .white
        }
    }

    private func fill(_ kind: Kind) -> Color {
        switch (style, kind) {
        case (.hero, .connect): return .white
        case (.hero, .disconnect): return Color.white.opacity(0.16)
        case (.card, .connect): return Brand.primary
        case (.card, .disconnect): return Brand.danger
        }
    }

    private func stroke(_ kind: Kind) -> Color {
        switch (style, kind) {
        case (.hero, .connect): return .clear
        case (.hero, .disconnect): return Color.white.opacity(0.45)
        case (.card, .connect): return .clear
        case (.card, .disconnect): return .clear
        }
    }
}

/// Adaptive button rows without custom Layout (avoids ScrollView layout hangs).
struct ButtonRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            content()
        }
    }
}
