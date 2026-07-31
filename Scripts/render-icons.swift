#!/usr/bin/env swift
// Renders the MDEditor app icon (all AppIcon.appiconset sizes) and
// Assets/logo.png with true alpha. Run from the repo root:
//   swift Scripts/render-icons.swift
//
// Geometry follows Apple's 1024pt icon grid: the visible squircle occupies
// the centered 824pt "icon area" so the Dock size matches other apps.
import AppKit

let canvas: CGFloat = 1024

// MARK: - Geometry (SVG-style coordinates, y-down)

/// Apple-style squircle approximated by a superellipse |cos|^0.44 / |sin|^0.44.
func squirclePath(half: CGFloat, center: CGFloat, n: Double = 4.5) -> NSBezierPath {
    let path = NSBezierPath()
    let segments = 128
    for i in 0..<segments {
        let t = 2 * Double.pi * Double(i) / Double(segments)
        let c = cos(t), s = sin(t)
        let x = center + half * (c >= 0 ? 1 : -1) * pow(abs(c), 2.0 / n)
        let y = center + half * (s >= 0 ? 1 : -1) * pow(abs(s), 2.0 / n)
        let p = NSPoint(x: x, y: y)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}

/// Open-book glyph, sized to the 824pt icon area.
func bookPath() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 512, y: 435))
    p.curve(to: NSPoint(x: 240, y: 369), controlPoint1: NSPoint(x: 453, y: 386), controlPoint2: NSPoint(x: 358, y: 358))
    p.line(to: NSPoint(x: 240, y: 655))
    p.curve(to: NSPoint(x: 512, y: 700), controlPoint1: NSPoint(x: 358, y: 645), controlPoint2: NSPoint(x: 453, y: 662))
    p.curve(to: NSPoint(x: 784, y: 655), controlPoint1: NSPoint(x: 571, y: 662), controlPoint2: NSPoint(x: 666, y: 645))
    p.line(to: NSPoint(x: 784, y: 369))
    p.curve(to: NSPoint(x: 512, y: 435), controlPoint1: NSPoint(x: 666, y: 358), controlPoint2: NSPoint(x: 571, y: 386))
    p.close()
    return p
}

// MARK: - Colors

let topBlue = NSColor(srgbRed: 0x63/255.0, green: 0xA9/255.0, blue: 0xFF/255.0, alpha: 1)
let bottomBlue = NSColor(srgbRed: 0x0A/255.0, green: 0x54/255.0, blue: 0xEB/255.0, alpha: 1)
let spineBlue = NSColor(srgbRed: 0x0B/255.0, green: 0x4F/255.0, blue: 0xD6/255.0, alpha: 0.20)

// MARK: - Renderer

func render(pixels: Int, to url: URL, shadow: Bool) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let scale = CGFloat(pixels) / canvas
    // Flip vertically so we can use SVG (y-down) coordinates, and scale the
    // 1024pt canvas down to the output size in one step.
    ctx.cgContext.translateBy(x: 0, y: CGFloat(pixels))
    ctx.cgContext.scaleBy(x: scale, y: -scale)

    let squircle = squirclePath(half: 412, center: 512)

    if shadow {
        ctx.cgContext.setShadow(
            offset: CGSize(width: 0, height: 10), // flipped context: renders downward
            blur: 18,
            color: NSColor(srgbRed: 0, green: 0x1A/255.0, blue: 0x4D/255.0, alpha: 0.28).cgColor
        )
        NSColor.black.setFill()
        squircle.fill()
        ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    }

    // Background gradient, light top -> dark bottom. Drawn with CGGradient
    // and explicit points: in the flipped context the points mean exactly
    // what they say (y grows downward).
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let cg = ctx.cgContext
    if let bg = CGGradient(colorsSpace: colorSpace,
                           colors: [topBlue.cgColor, bottomBlue.cgColor] as CFArray,
                           locations: [0, 1]) {
        cg.saveGState()
        squircle.addClip()
        cg.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        cg.restoreGState()
    }

    // Top sheen.
    if let sheen = CGGradient(colorsSpace: colorSpace,
                              colors: [NSColor.white.withAlphaComponent(0.14).cgColor,
                                       NSColor.white.withAlphaComponent(0).cgColor,
                                       NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 0.38, 1]) {
        cg.saveGState()
        squircle.addClip()
        cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        cg.restoreGState()
    }

    // Book + spine.
    NSColor.white.setFill()
    bookPath().fill()
    let spine = NSBezierPath()
    spine.move(to: NSPoint(x: 512, y: 435))
    spine.line(to: NSPoint(x: 512, y: 700))
    spine.lineWidth = 11
    spine.lineCapStyle = .round
    spineBlue.setStroke()
    spine.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-icons", code: 1)
    }
    try png.write(to: url)
}

// MARK: - Main

let fm = FileManager.default
let root = fm.currentDirectoryPath
let iconset = "\(root)/MDEditor/Assets.xcassets/AppIcon.appiconset"
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    try render(pixels: px, to: URL(fileURLWithPath: "\(iconset)/\(name)"), shadow: false)
}
try render(pixels: 512, to: URL(fileURLWithPath: "\(root)/Assets/logo.png"), shadow: true)
print("Rendered \(sizes.count) iconset PNGs + Assets/logo.png")
