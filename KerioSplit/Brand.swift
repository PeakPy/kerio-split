import SwiftUI
import AppKit

enum Brand {
    static let primary = Color(red: 0x1d / 255, green: 0x78 / 255, blue: 0xcd / 255)
    static let deep = Color(red: 0x11 / 255, green: 0x44 / 255, blue: 0x7b / 255)
    static let ink = Color(red: 0.06, green: 0.12, blue: 0.22)
    static let mist = Color(red: 0.93, green: 0.96, blue: 0.99)
    static let success = Color(red: 0.18, green: 0.72, blue: 0.48)
    static let danger = Color(red: 0.86, green: 0.28, blue: 0.32)

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [deep, primary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var logoImage: NSImage {
        if let url = Bundle.main.url(forResource: "MehradLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        let fallback = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("KerioSplit/Assets.xcassets/MehradLogo.imageset/tom.h@example.org")
        if let img = NSImage(contentsOf: fallback) {
            return img
        }
        return NSImage(size: NSSize(width: 48, height: 48))
    }
}
