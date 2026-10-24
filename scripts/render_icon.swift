// Renders the app icon PNGs into the asset catalog.
//
//   swift scripts/render_icon.swift
//
// Geometry matches `BrandGlyph` / `BrandMark` in Views/Theme.swift: three server
// blades stepping down in width to form a "V", each with a status LED cut out,
// white on an ember-gradient squircle laid out on Apple's 1024pt macOS icon grid.
import AppKit
import CoreGraphics
import SwiftUI

let outDir = "Sources/VPSManager/Resources/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's continuous-corner rounded rect (the exact shape SwiftUI uses for
/// `.continuous`), at the macOS icon grid's 185.4/824 corner ratio.
func squircle(in rect: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: rect.width * 185.4 / 824, style: .continuous).path(in: rect).cgPath
}

/// Same math as BrandGlyph.path(in:), in a y-down space flipped into CG's y-up.
func glyph(in rect: CGRect) -> CGPath {
    let s = min(rect.width, rect.height)
    let ox = rect.midX - s / 2
    let barHeight = 0.15 * s
    let gap = 0.065 * s
    let widths: [CGFloat] = [0.76, 0.55, 0.34].map { $0 * s }
    let total = barHeight * 3 + gap * 2
    var yTop = (s - total) / 2
    let radius = barHeight * 0.32
    let path = CGMutablePath()
    for width in widths {
        let x = ox + (s - width) / 2
        // convert y-down offset to CG y-up within rect
        let y = rect.maxY - yTop - barHeight - (rect.height - s) / 2
        let bar = CGRect(x: x, y: y, width: width, height: barHeight)
        path.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        let led = barHeight * 0.34
        path.addEllipse(in: CGRect(x: x + barHeight * 0.42, y: bar.midY - led / 2, width: led, height: led))
        yTop += barHeight + gap
    }
    return path
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = size / 1024
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = squircle(in: tile)

    // Drop shadow under the tile (part of the standard macOS icon template).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 22 * k, color: color(0x000000, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(color(0xE0311B))
    ctx.fillPath()
    ctx.restoreGState()

    // Brand gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [color(0xFF8A3D), color(0xE0311B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    // Soft sheen across the top half.
    let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.midY), options: [])
    ctx.restoreGState()

    // Hairline inner edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(max(1, 4 * k))
    ctx.strokePath()
    ctx.restoreGState()

    // Glyph — same inset ratio as BrandMark (14% padding).
    let inset = tile.width * 0.14
    let glyphRect = tile.insetBy(dx: inset, dy: inset)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 14 * k, color: color(0x7A1A08, 0.35))
    ctx.addPath(glyph(in: glyphRect))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, px) in outputs {
    try! render(pixels: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("wrote \(name)")
}
