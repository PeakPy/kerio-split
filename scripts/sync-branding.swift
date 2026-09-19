#!/usr/bin/env swift
import AppKit
import Foundation

/// Derive branding surfaces from ONE master app icon.
/// - Cleans white corners / fringe → true transparency around the squircle
/// - App icon / badge: full colored squircle on clear
/// - Mark: cyan glyph only
/// - Template mark: white glyph for menu bar

let repo = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let masterURL = repo.appendingPathComponent("assets/branding/logo/app-icon-1024.png")
// Master must already be RGBA with transparent corners (Scripts/clean-logo-alpha.py).
guard let master = NSImage(contentsOf: masterURL) else {
    fputs("missing master logo: \(masterURL.path)\n", stderr)
    exit(1)
}
print("using cleaned master plate")

func bitmap(from image: NSImage) -> NSBitmapImageRep? {
    guard let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

func savePNG(_ rep: NSBitmapImageRep, relative: String) {
    let url = repo.appendingPathComponent(relative)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("encode failed \(relative)\n", stderr)
        exit(1)
    }
    try! png.write(to: url)
    print("wrote \(relative)")
}

func saveImage(_ image: NSImage, relative: String) {
    guard let rep = bitmap(from: image) else { exit(1) }
    savePNG(rep, relative: relative)
}

func rgbaRep(width w: Int, height h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: w * 4,
        bitsPerPixel: 32
    )!
}

/// Remove white canvas + thin white halo around the dark squircle.
func makePlateTransparent(from image: NSImage) -> NSBitmapImageRep {
    guard let src = bitmap(from: image) else {
        fputs("no bitmap for plate clean\n", stderr)
        exit(1)
    }
    let w = src.pixelsWide
    let h = src.pixelsHigh
    let out = rgbaRep(width: w, height: h)

    func sample(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0, 0) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    func isBackground(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let sat = max(r, max(g, b)) - min(r, min(g, b))
        // White / light-gray canvas only (not cyan glyph, not navy plate).
        return luma > 0.82 && sat < 0.14
    }

    // Flood-fill near-white from all four corners + edge midpoints.
    var bg = [Bool](repeating: false, count: w * h)
    var stack: [(Int, Int)] = [
        (0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
        (w / 2, 0), (w / 2, h - 1), (0, h / 2), (w - 1, h / 2)
    ]
    while let (x, y) = stack.popLast() {
        if x < 0 || y < 0 || x >= w || y >= h { continue }
        let i = y * w + x
        if bg[i] { continue }
        let (r, g, b, _) = sample(x, y)
        if !isBackground(r, g, b) { continue }
        bg[i] = true
        stack.append((x + 1, y))
        stack.append((x - 1, y))
        stack.append((x, y + 1))
        stack.append((x, y - 1))
    }

    // Extra pass: peel thin white halo stuck to the squircle rim (1–2px).
    for _ in 0..<3 {
        var next = bg
        for y in 1..<h - 1 {
            for x in 1..<w - 1 {
                let i = y * w + x
                if bg[i] { continue }
                let (r, g, b, _) = sample(x, y)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let sat = max(r, max(g, b)) - min(r, min(g, b))
                // Only peel light desaturated fringe next to already-cleared bg.
                guard luma > 0.72 && sat < 0.16 else { continue }
                var touchingBg = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        if bg[(y + dy) * w + (x + dx)] { touchingBg = true }
                    }
                }
                if touchingBg { next[i] = true }
            }
        }
        bg = next
    }

    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            let (r, g, b, a) = sample(x, y)
            if bg[i] {
                out.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y)
            } else {
                out.setColor(NSColor(deviceRed: r, green: g, blue: b, alpha: max(a, 1)), atX: x, y: y)
            }
        }
    }
    return out
}

/// Keep bright cyan glyph; punch out dark squircle → transparent.
func extractMark(from image: NSImage, asTemplate: Bool) -> NSBitmapImageRep {
    guard let src = bitmap(from: image) else {
        fputs("no bitmap\n", stderr)
        exit(1)
    }
    let w = src.pixelsWide
    let h = src.pixelsHigh
    let out = rgbaRep(width: w, height: h)

    for y in 0..<h {
        for x in 0..<w {
            guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            if a < 0.05 {
                out.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y)
                continue
            }
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let isGlyph = luma > 0.22 && b > 0.28 && b >= r * 0.75
            if isGlyph {
                let alpha = max(a, min(1, luma * 1.15))
                if asTemplate {
                    out.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: alpha), atX: x, y: y)
                } else {
                    out.setColor(NSColor(deviceRed: r, green: g, blue: b, alpha: alpha), atX: x, y: y)
                }
            } else {
                out.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y)
            }
        }
    }
    return out
}

/// Crop to opaque bounds + padding, then scale into a square canvas (fills menu bar better).
func cropTight(_ src: NSBitmapImageRep, paddingRatio: CGFloat = 0.14, outputSide: Int = 512) -> NSBitmapImageRep {
    var minX = src.pixelsWide, minY = src.pixelsHigh, maxX = 0, maxY = 0
    var hits = 0
    for y in 0..<src.pixelsHigh {
        for x in 0..<src.pixelsWide {
            guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            if a > 0.06 {
                hits += 1
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    guard hits > 50 else { return src }

    let bw = maxX - minX + 1
    let bh = maxY - minY + 1
    let pad = Int(CGFloat(max(bw, bh)) * paddingRatio)
    minX = max(0, minX - pad)
    minY = max(0, minY - pad)
    maxX = min(src.pixelsWide - 1, maxX + pad)
    maxY = min(src.pixelsHigh - 1, maxY + pad)
    let cw = maxX - minX + 1
    let ch = maxY - minY + 1

    let cropped = NSImage(size: NSSize(width: cw, height: ch))
    cropped.lockFocus()
    src.draw(in: NSRect(x: 0, y: 0, width: cw, height: ch),
             from: NSRect(x: minX, y: minY, width: cw, height: ch),
             operation: .copy,
             fraction: 1,
             respectFlipped: true,
             hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    cropped.unlockFocus()

    let side = outputSide
    let square = NSImage(size: NSSize(width: side, height: side))
    square.lockFocus()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    let scale = CGFloat(side) * 0.92 / CGFloat(max(cw, ch))
    let dw = CGFloat(cw) * scale
    let dh = CGFloat(ch) * scale
    cropped.draw(in: NSRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh),
                 from: .zero, operation: .sourceOver, fraction: 1)
    square.unlockFocus()

    return bitmap(from: square) ?? src
}

let colorMark = cropTight(extractMark(from: master, asTemplate: false))
let templateMark = cropTight(extractMark(from: master, asTemplate: true))
savePNG(colorMark, relative: "assets/branding/logo/app-mark.png")
savePNG(templateMark, relative: "assets/branding/logo/app-mark-template.png")

savePNG(colorMark, relative: "platforms/macos/KerioSplit/Resources/AppMark.png")
savePNG(templateMark, relative: "platforms/macos/KerioSplit/Resources/AppMarkTemplate.png")

let midnight = NSColor(calibratedRed: 0x11/255, green: 0x18/255, blue: 0x27/255, alpha: 1)

func canvas(width: CGFloat, height: CGFloat, draw: () -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    draw()
    image.unlockFocus()
    return image
}

// Hero / social / features still use the FULL icon (with plate) for brand recognition.
saveImage(canvas(width: 1600, height: 900) {
    midnight.setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
    let iconSize: CGFloat = 360
    master.draw(in: NSRect(x: 1080, y: 270, width: iconSize, height: iconSize),
                from: .zero, operation: .sourceOver, fraction: 1)
    ("Kerio Split" as NSString).draw(
        at: NSPoint(x: 96, y: 520),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.white
        ])
    ("Split tunneling for Kerio Control VPN" as NSString).draw(
        at: NSPoint(x: 96, y: 460),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)
        ])
    ("macOS · Linux · Windows" as NSString).draw(
        at: NSPoint(x: 96, y: 400),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0x38/255, green: 0xbd/255, blue: 0xf8/255, alpha: 1)
        ])
}, relative: "assets/branding/banner-hero.png")

saveImage(canvas(width: 1024, height: 1024) {
    midnight.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let iconSize: CGFloat = 420
    master.draw(in: NSRect(x: (1024-iconSize)/2, y: 320, width: iconSize, height: iconSize),
                from: .zero, operation: .sourceOver, fraction: 1)
    let title = "Kerio Split" as NSString
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 54, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let tw = title.size(withAttributes: titleAttrs).width
    title.draw(at: NSPoint(x: (1024-tw)/2, y: 220), withAttributes: titleAttrs)
    let by = "Open-source companion" as NSString
    let byAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1)
    ]
    let bw = by.size(withAttributes: byAttrs).width
    by.draw(at: NSPoint(x: (1024-bw)/2, y: 170), withAttributes: byAttrs)
}, relative: "assets/branding/social-card.png")

saveImage(canvas(width: 1600, height: 520) {
    midnight.setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 520).fill()
    // Features strip uses TRANSPARENT mark on dark bg (not stacked squircles)
    guard let markImg = NSImage(data: colorMark.representation(using: .png, properties: [:])!) else { return }
    let size: CGFloat = 140
    let labels = ["VPN routes", "Bypass", "Multi-platform"]
    for (i, x) in [240, 730, 1220].enumerated() {
        markImg.draw(in: NSRect(x: CGFloat(x), y: 200, width: size, height: size),
                     from: .zero, operation: .sourceOver, fraction: 1)
        let label = labels[i] as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let w = label.size(withAttributes: attrs).width
        label.draw(at: NSPoint(x: CGFloat(x) + (size-w)/2, y: 130), withAttributes: attrs)
    }
}, relative: "assets/branding/banner-features.png")

print("branding surfaces OK")
