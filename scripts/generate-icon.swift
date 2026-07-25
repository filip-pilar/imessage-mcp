import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let outputs: [(String, Int)] = [
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

for (name, pixels) in outputs {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw NSError(domain: "Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let inset = CGFloat(pixels) * 0.055
    let outer = NSRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2)
    let radius = CGFloat(pixels) * 0.225

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.08, green: 0.63, blue: 0.98, alpha: 1),
        ending: NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.48, alpha: 1)
    )!
    let background = NSBezierPath(roundedRect: outer, xRadius: radius, yRadius: radius)
    gradient.draw(in: background, angle: -55)

    let bubbleRect = NSRect(
        x: CGFloat(pixels) * 0.205,
        y: CGFloat(pixels) * 0.275,
        width: CGFloat(pixels) * 0.59,
        height: CGFloat(pixels) * 0.46
    )
    let bubble = NSBezierPath(
        roundedRect: bubbleRect,
        xRadius: CGFloat(pixels) * 0.20,
        yRadius: CGFloat(pixels) * 0.20
    )
    NSColor.white.setFill()
    bubble.fill()

    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: CGFloat(pixels) * 0.31, y: CGFloat(pixels) * 0.325))
    tail.line(to: NSPoint(x: CGFloat(pixels) * 0.255, y: CGFloat(pixels) * 0.205))
    tail.line(to: NSPoint(x: CGFloat(pixels) * 0.43, y: CGFloat(pixels) * 0.30))
    tail.close()
    tail.fill()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "Icon", code: 1)
    }
    try png.write(to: directory.appendingPathComponent(name))
}
