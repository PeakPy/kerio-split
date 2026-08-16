import SwiftUI

// MARK: - Layout primitives

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(20)
                .frame(maxWidth: 820, alignment: .topLeading)
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
