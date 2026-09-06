// Renders the app icon into a .iconset directory, which `scripts/package-app.sh`
// then hands to `iconutil` to produce Resources/AppIcon.icns.
//
// The glyph is the `display` SF Symbol — the same one the status item draws in
// the menu bar (StatusMenuController.swift) and the same one the display picker
// numbers. Taking it from the system rather than transcribing a path is what
// keeps the icon and the menu bar from drifting apart: there is one symbol, and
// if Apple redraws it both follow.
//
// The tile matches InOut's icon so the two sit together as a pair.

import AppKit
import Foundation

private enum Tile {
    /// Proportions of the macOS icon grid: the rounded square occupies the
    /// middle ~80% of the canvas, leaving the margin the system expects for
    /// shadows and optical alignment against other icons.
    static let inset: CGFloat = 100.0 / 1024.0
    static let cornerRadius: CGFloat = 185.0 / 1024.0

    /// Glyph size as a fraction of the tile.
    ///
    /// Larger than InOut's 0.60 because `display` is a wide, squat symbol: fitted
    /// by its longest side it reads smaller than a square glyph of the same
    /// nominal box, and at 16pt an under-sized monitor turns to mush.
    static let glyphFraction: CGFloat = 0.66

    static let top = NSColor(srgbRed: 0.243, green: 0.271, blue: 0.325, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.086, green: 0.102, blue: 0.129, alpha: 1)
    static let stroke = NSColor(srgbRed: 0.965, green: 0.973, blue: 0.984, alpha: 1)
}

private func render(pixels: Int) -> NSBitmapImageRep? {
    let side = CGFloat(pixels)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let inset = side * Tile.inset
    let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * Tile.cornerRadius
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(starting: Tile.bottom, ending: Tile.top)?.draw(in: tilePath, angle: 90)

    let box = tile.width * Tile.glyphFraction
    guard
        let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: box, weight: .regular))
    else { return nil }
    symbol.isTemplate = true

    // Fitted by whichever side runs out first, so the monitor keeps its shape
    // instead of being stretched to fill a square it was never drawn for.
    let fit = min(box / symbol.size.width, box / symbol.size.height)
    let drawn = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
    let frame = NSRect(
        x: tile.midX - drawn.width / 2,
        y: tile.midY - drawn.height / 2,
        width: drawn.width,
        height: drawn.height)

    // The transparency layer is load-bearing. `.sourceAtop` recolours whatever
    // it finds underneath it, so without a layer to scope it to, the fill would
    // land on the gradient tile as well and paint the whole icon flat white.
    // Inside the layer the only thing under the fill is the glyph's own alpha.
    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: frame)
    Tile.stroke.setFill()
    frame.fill(using: .sourceAtop)
    context.cgContext.endTransparencyLayer()

    return rep
}

/// The exact set `iconutil` expects; anything missing makes it refuse the
/// directory outright.
private let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon <output.iconset>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for variant in variants {
    guard
        let rep = render(pixels: variant.pixels),
        let data = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: directory.appendingPathComponent(variant.name))
}

print("Wrote \(variants.count) images to \(directory.path)")
