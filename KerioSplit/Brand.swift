import SwiftUI
import AppKit

enum Brand {
    /// Mehrad blues stay constant across themes.
    static let primary = Color(red: 0x1d / 255, green: 0x78 / 255, blue: 0xcd / 255)
    static let deep = Color(red: 0x11 / 255, green: 0x44 / 255, blue: 0x7b / 255)
    static let success = Color(red: 0.18, green: 0.70, blue: 0.48)
    static let danger = Color(red: 0.86, green: 0.30, blue: 0.32)
    static let warn = Color(red: 0.90, green: 0.60, blue: 0.15)

    static let ink = Color(light: Color(red: 0.07, green: 0.11, blue: 0.18),
                           dark: Color(red: 0.93, green: 0.95, blue: 0.98))
    static let mist = Color(light: Color(red: 0.945, green: 0.961, blue: 0.980),
                            dark: Color(red: 0.09, green: 0.11, blue: 0.15))
    static let panel = Color(light: .white,
                             dark: Color(red: 0.13, green: 0.15, blue: 0.19))
    static let sidebar = Color(light: Color(red: 0.97, green: 0.98, blue: 0.99),
                               dark: Color(red: 0.11, green: 0.12, blue: 0.16))
    static let line = Color(light: Color.black.opacity(0.08),
                            dark: Color.white.opacity(0.10))
    static let muted = Color(light: Color.black.opacity(0.45),
                             dark: Color.white.opacity(0.55))
    static let field = Color(light: Color(red: 0.945, green: 0.961, blue: 0.980),
                             dark: Color(red: 0.16, green: 0.18, blue: 0.23))

    static var heroGradient: LinearGradient {
        LinearGradient(colors: [deep, primary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var softGradient: LinearGradient {
        LinearGradient(
            colors: [
                deep.opacity(0.12),
                primary.opacity(0.07),
                mist
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var logoImage: NSImage {
        cachedLogo
    }

    /// White-on-transparent Mehrad mark for tinting (sidebar, hero, menu bar).
    static var markImage: NSImage {
        cachedMark
    }

    static var menuBarImage: NSImage {
        let img = cachedMark.copy() as? NSImage ?? cachedMark
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }

    private static let cachedLogo: NSImage = {
        if let url = Bundle.main.url(forResource: "MehradLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return markImage
    }()

    private static let cachedMark: NSImage = {
        let candidates = [
            Bundle.main.url(forResource: "MehradMark", withExtension: "png"),
            Bundle.main.url(forResource: "MehradLogo", withExtension: "png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Assets.xcassets/MehradLogo.imageset/mehrad-mark.png")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                return img
            }
        }
        return NSImage(size: NSSize(width: 48, height: 48))
    }()
}

/// Canonical Mehrad mark. Use this instead of SF Symbol stand-ins.
struct BrandLogo: View {
    enum Style {
        case mark
        case badge
    }

    var size: CGFloat = 32
    var style: Style = .badge
    var tint: Color = .white

    var body: some View {
        switch style {
        case .mark:
            Image(nsImage: Brand.markImage)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        case .badge:
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Brand.heroGradient)
                Image(nsImage: Brand.markImage)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.2)
            }
            .frame(width: size, height: size)
            .shadow(color: Brand.deep.opacity(0.18), radius: 6, y: 2)
        }
    }
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case vpnRoutes
    case bypass
    case settings
    case json
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .vpnRoutes: return "VPN Routes"
        case .bypass: return "Bypass"
        case .settings: return "Settings"
        case .json: return "JSON"
        case .activity: return "Activity"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "bolt.horizontal.circle.fill"
        case .vpnRoutes: return "point.3.connected.trianglepath.dotted"
        case .bypass: return "arrow.triangle.branch"
        case .settings: return "gearshape.fill"
        case .json: return "curlybraces"
        case .activity: return "list.bullet.rectangle"
        }
    }
}
