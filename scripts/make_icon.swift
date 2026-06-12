// Generates Assets/AppIcon.icns - a lightning bolt on a green gradient
// rounded square. Run: swift scripts/make_icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.05
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.45, alpha: 1),
        ending: NSColor(calibratedRed: 0.02, green: 0.45, blue: 0.55, alpha: 1)
    )
    gradient?.draw(in: path, angle: -60)

    // Lightning bolt polygon, coordinates in unit space (y up)
    let bolt: [(CGFloat, CGFloat)] = [
        (0.58, 0.90), (0.32, 0.50), (0.47, 0.50),
        (0.42, 0.10), (0.68, 0.52), (0.53, 0.52),
    ]
    let boltPath = NSBezierPath()
    for (i, point) in bolt.enumerated() {
        let p = NSPoint(x: point.0 * size, y: point.1 * size)
        if i == 0 { boltPath.move(to: p) } else { boltPath.line(to: p) }
    }
    boltPath.close()
    NSColor.white.setFill()
    boltPath.fill()

    image.unlockFocus()
    return image
}

let iconset = "Assets/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(points * scale)
        let image = drawIcon(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { fatalError("render failed") }
        let suffix = scale == 1 ? "" : "@2x"
        try! png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points)\(suffix).png"))
    }
}

print("iconset written - now run: iconutil -c icns \(iconset) -o Assets/AppIcon.icns")
