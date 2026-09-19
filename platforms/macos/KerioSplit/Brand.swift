import SwiftUI
import AppKit

enum Brand {
    /// Logo mark color (cyan on midnight plate).
    static let primary = Color(red: 0x38 / 255, green: 0xbd / 255, blue: 0xf8 / 255)
    static let primarySoft = Color(red: 0x7d / 255, green: 0xd3 / 255, blue: 0xfc / 255)
    static let deep = Color(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255)
    static let deepLift = Color(red: 0x1e / 255, green: 0x29 / 255, blue: 0x3b / 255)
    static let success = Color(red: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255)
    static let danger = Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255)
    static let warn = Color(red: 0xf5 / 255, green: 0x9e / 255, blue: 0x0b / 255)

    static let ink = Color(light: Color(red: 0x0f / 255, green: 0x17 / 255, blue: 0x2a / 255),
                           dark: Color(red: 0xf1 / 255, green: 0xf5 / 255, blue: 0xf9 / 255))
    static let mist = Color(light: Color(red: 0xf0 / 255, green: 0xf7 / 255, blue: 0xfc / 255),
                            dark: Color(red: 0x0b / 255, green: 0x12 / 255, blue: 0x20 / 255))
    static let panel = Color(light: Color.white,
                             dark: Color(red: 0x15 / 255, green: 0x1c / 255, blue: 0x2c / 255))
    static let sidebar = Color(light: Color(red: 0xf8 / 255, green: 0xfb / 255, blue: 0xfe / 255),
                               dark: Color(red: 0x0f / 255, green: 0x16 / 255, blue: 0x24 / 255))
    static let line = Color(light: Color(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255).opacity(0.08),
                            dark: Color.white.opacity(0.10))
    static let muted = Color(light: Color(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255).opacity(0.48),
                             dark: Color.white.opacity(0.55))
    static let field = Color(light: Color(red: 0xef / 255, green: 0xf6 / 255, blue: 0xfb / 255),
                             dark: Color(red: 0x1a / 255, green: 0x22 / 255, blue: 0x33 / 255))

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [deep, deepLift, Color(red: 0x0e / 255, green: 0x4a / 255, blue: 0x6e / 255)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [primary, primarySoft], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var softGradient: LinearGradient {
        LinearGradient(
            colors: [
                primary.opacity(0.10),
                deep.opacity(0.04),
                mist
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Full plate icon — Dock, sidebar badge, packaging.
    static var logoImage: NSImage { cachedLogo }

    /// Same logo, cyan glyph only / transparent — overlays & in-app marks.
    static var markImage: NSImage { cachedMark }

    /// Same logo as template (no plate) for menu bar.
    static var menuBarImage: NSImage {
        let source = cachedTemplate
        let img = source.copy() as? NSImage ?? source
        img.size = NSSize(width: 24, height: 24)
        img.isTemplate = true
        return img
    }

    private static let cachedLogo: NSImage = {
        loadFirst([
            Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/AppLogo.png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon_512.png")
        ]) ?? NSImage(size: NSSize(width: 64, height: 64))
    }()

    private static let cachedMark: NSImage = {
        loadFirst([
            Bundle.main.url(forResource: "AppMark", withExtension: "png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/AppMark.png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Assets.xcassets/AppMark.imageset/app-mark.png")
        ]) ?? cachedLogo
    }()

    private static let cachedTemplate: NSImage = {
        loadFirst([
            Bundle.main.url(forResource: "AppMarkTemplate", withExtension: "png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/AppMarkTemplate.png"),
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("../../../../assets/branding/logo/app-mark-template.png")
        ]) ?? cachedMark
    }()

    private static func loadFirst(_ urls: [URL?]) -> NSImage? {
        for url in urls.compactMap({ $0 }) {
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }
}

/// One logo, two presentations: plate (`badge`) or transparent glyph (`mark`).
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
        case .badge:
            Image(nsImage: Brand.logoImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.223, style: .continuous))
                .shadow(color: Brand.deep.opacity(0.20), radius: 8, y: 3)
        case .mark:
            Image(nsImage: Brand.markImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
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
    case outbound
    case settings
    case json
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .vpnRoutes: return "VPN Routes"
        case .bypass: return "Bypass"
        case .outbound: return "Outbound"
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
        case .outbound: return "arrow.up.right.circle.fill"
        case .settings: return "gearshape.fill"
        case .json: return "curlybraces"
        case .activity: return "list.bullet.rectangle"
        }
    }
}
