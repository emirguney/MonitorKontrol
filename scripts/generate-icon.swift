// Renders the MonitorKontrol app icon into an .iconset directory.
// Usage: xcrun swift scripts/generate-icon.swift <output.iconset>
import AppKit

let canvas: CGFloat = 1024
// Apple macOS icon grid: 824pt body inside a 1024pt canvas.
let bodyInset: CGFloat = 100
let bodyCornerRadius: CGFloat = 185

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func symbol(_ name: String, pointSize: CGFloat, color: NSColor, weight: NSFont.Weight) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        FileHandle.standardError.write(Data("Missing SF Symbol: \(name)\n".utf8))
        exit(1)
    }
    return image
}

func draw(_ image: NSImage, centeredAt center: CGPoint, scale: CGFloat) {
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    image.draw(in: rect)
}

func renderIcon(pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        FileHandle.standardError.write(Data("Could not create bitmap context\n".utf8))
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / canvas
    context.cgContext.scaleBy(x: scale, y: scale)

    let bodyRect = NSRect(x: bodyInset, y: bodyInset, width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: bodyCornerRadius, yRadius: bodyCornerRadius)
    NSGradient(
        starting: NSColor(srgbRed: 0.33, green: 0.58, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.62, alpha: 1)
    )?.draw(in: body, angle: -90)

    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    draw(symbol("display", pointSize: 420, color: .white, weight: .semibold), centeredAt: center, scale: 1)
    let sunCenter = CGPoint(x: center.x, y: center.y + 38)
    let sunColor = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.30, alpha: 1)
    draw(symbol("sun.max.fill", pointSize: 150, color: sunColor, weight: .bold), centeredAt: sunCenter, scale: 1)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG encoding failed\n".utf8))
        exit(1)
    }
    return png
}

do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for multiplier in [1, 2] {
            let suffix = multiplier == 2 ? "@2x" : ""
            let fileURL = outputURL.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
            try renderIcon(pixels: points * multiplier).write(to: fileURL)
        }
    }
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error)\n".utf8))
    exit(1)
}
