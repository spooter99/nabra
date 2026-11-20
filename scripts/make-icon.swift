// Draws the Nabra app icon at every size macOS needs and writes the asset catalog entry.
// Usage: swift scripts/make-icon.swift <output .appiconset directory>
import AppKit

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = CGFloat(pixels) / 1024
    cg.scaleBy(x: scale, y: scale)

    // Standard macOS icon body: 824 pt rounded square centred on a 1024 pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    cg.addPath(bodyPath)
    cg.setFillColor(NSColor(red: 0.30, green: 0.27, blue: 0.80, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    let colors = [NSColor(red: 0.23, green: 0.22, blue: 0.72, alpha: 1).cgColor,
                  NSColor(red: 0.42, green: 0.31, blue: 0.90, alpha: 1).cgColor,
                  NSColor(red: 0.72, green: 0.36, blue: 0.95, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft glow behind the bars.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 380, options: [])

    // The notch: a black tab hanging from the top edge.
    let notchWidth: CGFloat = 330
    let notchHeight: CGFloat = 104
    let notch = CGMutablePath()
    let top = body.maxY
    let left = 512 - notchWidth / 2
    let right = 512 + notchWidth / 2
    let radius: CGFloat = 44
    notch.move(to: CGPoint(x: left, y: top))
    notch.addLine(to: CGPoint(x: left, y: top - notchHeight + radius))
    notch.addArc(tangent1End: CGPoint(x: left, y: top - notchHeight), tangent2End: CGPoint(x: left + radius, y: top - notchHeight), radius: radius)
    notch.addLine(to: CGPoint(x: right - radius, y: top - notchHeight))
    notch.addArc(tangent1End: CGPoint(x: right, y: top - notchHeight), tangent2End: CGPoint(x: right, y: top - notchHeight + radius), radius: radius)
    notch.addLine(to: CGPoint(x: right, y: top))
    notch.closeSubpath()
    cg.addPath(notch)
    cg.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
    cg.fillPath()

    // Sound bars.
    let heights: [CGFloat] = [0.30, 0.58, 1.0, 0.70, 0.40]
    let barWidth: CGFloat = 64
    let gap: CGFloat = 44
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let maxHeight: CGFloat = 400
    let centreY: CGFloat = 448
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    for (index, height) in heights.enumerated() {
        let barHeight = maxHeight * height
        let rect = CGRect(x: 512 - total / 2 + CGFloat(index) * (barWidth + gap), y: centreY - barHeight / 2,
                          width: barWidth, height: barHeight)
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Hairline highlight around the edge.
    cg.addPath(bodyPath)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(3)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let rep = drawIcon(pixels: points * scale)
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons")
