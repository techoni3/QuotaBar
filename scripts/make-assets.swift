// Renders the AIMeter app icon master + DMG background as PNGs.
// Placeholder art, generated programmatically (documented source: this script).
//   swift scripts/make-assets.swift   (writes Assets/icon-master.png + Assets/dmg-background.png)
// Then: assets/make-app.sh / release.sh assemble the .icns via iconutil.
import AppKit
import Foundation

func render(size: Int, filename: String, block: (CGContext, CGFloat) -> Void) throws {
    let pixels = size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    block(ctx, CGFloat(size))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "assets", code: 1)
    }
    let url = URL(fileURLWithPath: "Assets/\(filename)")
    try data.write(to: url)
    print("wrote \(url.path)")
}

let baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsDir = baseDir.appendingPathComponent("Assets")
try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

// --- App icon master (1024²) ---
try render(size: 1024, filename: "icon-master.png") { ctx, s in
    // macOS Big-Sur-style tile: rounded square with ~22.4% corner radius. Match
    // the HUD gauge: white ring + colored usage arc + needle.
    let tile = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: tile, cornerWidth: s * 0.224, cornerHeight: s * 0.224, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1))
    ctx.fillPath()

    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = s * 0.30
    let lineWidth = s * 0.075
    // Full background ring.
    ctx.setStrokeColor(CGColor(red: 0.30, green: 0.32, blue: 0.38, alpha: 1))
    ctx.setLineWidth(lineWidth)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))
    // Usage arc: ~70% amber (matches HUD →warning threshold).
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.74, blue: 0.25, alpha: 1))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 1.5, endAngle: .pi * (1.5 + 0.70 * 2), clockwise: false)
    ctx.strokePath()
    // Needle (dial at top-right).
    let needleEnd = CGPoint(x: center.x + radius * 0.55, y: center.y + radius * 0.55)
    ctx.move(to: center)
    ctx.addLine(to: needleEnd)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(s * 0.035)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// --- DMG background (600×400) ---
try render(size: 600, filename: "dmg-background.png") { ctx, s in
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                                 CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    let title = NSAttributedString(string: "AIMeter",
                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 46),
                                                .foregroundColor: NSColor.white])
    let sub = NSAttributedString(string: "Drag to Applications",
                                 attributes: [.font: NSFont.systemFont(ofSize: 20),
                                              .foregroundColor: NSColor(white: 0.78, alpha: 1)])
    let titleSize = title.size(); let subSize = sub.size()
    title.draw(at: NSPoint(x: (s - titleSize.width) / 2, y: 260))
    sub.draw(at: NSPoint(x: (s - subSize.width) / 2, y: 210))

    // Right-side drop well.
    let well = CGRect(x: 360, y: 90, width: 200, height: 200)
    let wellPath = CGPath(roundedRect: well, cornerWidth: 16, cornerHeight: 16, transform: nil)
    ctx.addPath(wellPath)
    ctx.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.9))
    ctx.setLineWidth(3)
    ctx.setLineDash(phase: 0, lengths: [10, 6])
    ctx.strokePath()

    let hint = NSAttributedString(string: "AIMeter.app",
                                  attributes: [.font: NSFont.systemFont(ofSize: 14),
                                               .foregroundColor: NSColor(white: 0.7, alpha: 1)])
    let hintSize = hint.size()
    hint.draw(at: NSPoint(x: well.midX - hintSize.width / 2, y: well.midY - 4))
}