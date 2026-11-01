// Run from the repository root: swift scripts/generate-icon.swift
// Native vector drawing keeps the icon crisp at every macOS icon size.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/PaneRook.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

final class VectorPath {
    let native = NSBezierPath()
    var svg = ""
    @discardableResult func move(_ x: CGFloat, _ y: CGFloat) -> Self {
        native.move(to: NSPoint(x: x, y: y)); svg += "M\(x) \(y) "; return self
    }
    @discardableResult func line(_ x: CGFloat, _ y: CGFloat) -> Self {
        native.line(to: NSPoint(x: x, y: y)); svg += "L\(x) \(y) "; return self
    }
    @discardableResult func curve(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> Self {
        native.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: a, y: b), controlPoint2: NSPoint(x: c, y: d))
        svg += "C\(a) \(b) \(c) \(d) \(x) \(y) "; return self
    }
    @discardableResult func close() -> Self { native.close(); svg += "Z"; return self }
}

// A rook's battlements and base frame two file panels.
let rook = VectorPath()
    .move(250, 242).line(350, 242).line(350, 320).line(462, 320)
    .line(462, 242).line(562, 242).line(562, 320).line(674, 320)
    .line(674, 242).line(774, 242).line(774, 398)
    .curve(760, 423, 774, 409, 770, 417).line(711, 456)
    .line(684, 708).line(720, 708)
    .curve(744, 732, 734, 708, 744, 718).line(744, 784)
    .curve(720, 808, 744, 798, 734, 808).line(304, 808)
    .curve(280, 784, 290, 808, 280, 798).line(280, 732)
    .curve(304, 708, 280, 718, 290, 708).line(340, 708)
    .line(313, 456).line(264, 423)
    .curve(250, 398, 254, 417, 250, 409).close()

let panels = [NSRect(x: 365, y: 450, width: 130, height: 216),
              NSRect(x: 529, y: 450, width: 130, height: 216)]
let backdrop = NSRect(x: 64, y: 64, width: 896, height: 896)

func drawIcon(size: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.shouldAntialias = true
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(size))
    transform.scaleX(by: CGFloat(size) / 1024, yBy: -CGFloat(size) / 1024)
    transform.concat()

    let tile = NSBezierPath(roundedRect: backdrop, xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0x1A103C, alpha: 0.28)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    color(0x6E3CD2).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color(0xAB7CFA), color(0x7943DF), color(0x49269A)])!
        .draw(from: NSPoint(x: 180, y: 80), to: NSPoint(x: 840, y: 960), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, alpha: 0.20).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = color(0x24104E, alpha: 0.32)
    glyphShadow.shadowBlurRadius = 20
    glyphShadow.shadowOffset = NSSize(width: 0, height: -14)
    glyphShadow.set()
    color(0xFAF7FF).setFill()
    rook.native.fill()
    NSGraphicsContext.restoreGraphicsState()

    for (index, rect) in panels.enumerated() {
        (index == 0 ? color(0x8050D9) : color(0xD7C4F8)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 17, yRadius: 17).fill()
        for row in 0..<3 {
            (index == 0 ? color(0xFFFFFF, alpha: row == 0 ? 1 : 0.58) : color(0x7950B8, alpha: row == 0 ? 1 : 0.55)).setFill()
            let line = NSRect(x: rect.minX + 25, y: rect.minY + 36 + CGFloat(row) * 51,
                              width: row == 2 ? 54 : 80, height: 13)
            NSBezierPath(roundedRect: line, xRadius: 6.5, yRadius: 6.5).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

var panelSVG = ""
for (index, rect) in panels.enumerated() {
    panelSVG += "<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"130\" height=\"216\" rx=\"17\" fill=\"\(index == 0 ? "#8050d9" : "#d7c4f8")\"/>"
    for row in 0..<3 {
        panelSVG += "<rect x=\"\(rect.minX + 25)\" y=\"\(rect.minY + 36 + CGFloat(row) * 51)\" width=\"\(row == 2 ? 54 : 80)\" height=\"13\" rx=\"6.5\" fill=\"\(index == 0 ? "#ffffff" : "#7950b8")\" opacity=\"\(row == 0 ? 1 : index == 0 ? 0.58 : 0.55)\"/>"
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="PaneRook: two file panels within a rook">
  <defs>
    <linearGradient id="background" x1="0.1" y1="0" x2="0.9" y2="1">
      <stop stop-color="#ab7cfa"/><stop offset="0.5" stop-color="#7943df"/><stop offset="1" stop-color="#49269a"/>
    </linearGradient>
    <filter id="tileShadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dy="12" stdDeviation="12" flood-color="#1a103c" flood-opacity="0.28"/></filter>
    <filter id="glyphShadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dy="14" stdDeviation="10" flood-color="#24104e" flood-opacity="0.32"/></filter>
  </defs>
  <rect x="64" y="64" width="896" height="896" rx="202" fill="url(#background)" stroke="white" stroke-opacity="0.2" stroke-width="2" filter="url(#tileShadow)"/>
  <path d="\(rook.svg)" fill="#faf7ff" filter="url(#glyphShadow)"/>
  \(panelSVG)
</svg>
"""
try svg.write(to: root.appendingPathComponent("assets/icon.svg"), atomically: true, encoding: .utf8)
try drawIcon(size: 1024, to: root.appendingPathComponent("assets/icon.png"))
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/PaneRook.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "PaneRook.Icon", code: Int(iconutil.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil konnte das Iconset nicht konvertieren. In eingeschränkten Umgebungen iconutil außerhalb der Sandbox ausführen."])
}
print("Generated assets/icon.svg, assets/icon.png and Resources/PaneRook.icns")
