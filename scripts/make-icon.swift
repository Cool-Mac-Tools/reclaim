import AppKit

// Export the approved, already rounded artwork without adding masks or margins.
// Run from the repository root:
// swift scripts/make-icon.swift Resources/reclaim-icon-source.png

let args = CommandLine.arguments
guard args.count == 2, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <approved-source.png>\n".utf8))
    exit(1)
}
let fm = FileManager.default

func render(width: Int, height: Int, at path: String, draw: (NSRect) -> Void) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func exportIcon(_ size: Int, to path: String) throws {
    try render(width: size, height: size, at: path) { bounds in
        source.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

try fm.createDirectory(atPath: "Resources/AppIcon.iconset", withIntermediateDirectories: true)
try exportIcon(1024, to: "Resources/reclaim-appicon-1024.png")
for size in [16, 32, 128, 256, 512] {
    try exportIcon(size, to: "Resources/AppIcon.iconset/icon_\(size)x\(size).png")
    try exportIcon(size * 2, to: "Resources/AppIcon.iconset/icon_\(size)x\(size)@2x.png")
}
for (size, name) in [(16, "favicon-16.png"), (32, "favicon-32.png"), (48, "favicon.png"),
                     (180, "apple-touch-icon.png"), (192, "reclaim-icon-192.png"), (512, "reclaim-icon.png")] {
    try exportIcon(size, to: "docs/assets/\(name)")
}

func bytes(_ value: Int, count: Int, littleEndian: Bool = false) -> Data {
    let shifts = littleEndian ? Array(0..<count) : Array((0..<count).reversed())
    return Data(shifts.map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

// ICNS and ICO are containers: embed the exported PNGs without recompressing.
var iconChunks = Data()
for (type, name) in [
    ("icp4", "icon_16x16"), ("icp5", "icon_32x32"), ("icp6", "icon_32x32@2x"),
    ("ic07", "icon_128x128"), ("ic08", "icon_256x256"), ("ic09", "icon_512x512"),
    ("ic10", "icon_512x512@2x"), ("ic11", "icon_16x16@2x"),
    ("ic12", "icon_32x32@2x"), ("ic13", "icon_128x128@2x"), ("ic14", "icon_256x256@2x")
] {
    let png = try Data(contentsOf: URL(fileURLWithPath: "Resources/AppIcon.iconset/\(name).png"))
    iconChunks.append(Data(type.utf8))
    iconChunks.append(bytes(png.count + 8, count: 4))
    iconChunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bytes(iconChunks.count + 8, count: 4))
icns.append(iconChunks)
try icns.write(to: URL(fileURLWithPath: "Resources/AppIcon.icns"))

var ico = Data([0, 0, 1, 0, 3, 0])
var icoImages = Data()
for (size, name) in [(16, "favicon-16.png"), (32, "favicon-32.png"), (48, "favicon.png")] {
    let png = try Data(contentsOf: URL(fileURLWithPath: "docs/assets/\(name)"))
    ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0])
    ico.append(bytes(1, count: 2, littleEndian: true))
    ico.append(bytes(32, count: 2, littleEndian: true))
    ico.append(bytes(png.count, count: 4, littleEndian: true))
    ico.append(bytes(6 + 3 * 16 + icoImages.count, count: 4, littleEndian: true))
    icoImages.append(png)
}
ico.append(icoImages)
try ico.write(to: URL(fileURLWithPath: "docs/favicon.ico"))

// Keep the existing social-card layout and copy, using the same approved icon.
try render(width: 1200, height: 630, at: "docs/assets/og-reclaim.png") { bounds in
    NSColor(srgbRed: 251 / 255, green: 251 / 255, blue: 253 / 255, alpha: 1).setFill()
    bounds.fill()
    let blue = NSColor(srgbRed: 0, green: 113 / 255, blue: 227 / 255, alpha: 1)
    blue.setFill()
    NSRect(x: 0, y: 624, width: 1200, height: 6).fill()
    source.draw(in: NSRect(x: 510, y: 354, width: 180, height: 180), from: .zero, operation: .sourceOver, fraction: 1)
    func centered(_ value: String, y: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont(name: bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size)!
        (value as NSString).draw(in: NSRect(x: 40, y: y, width: 1120, height: size * 1.3), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
    centered("Reclaim", y: 214, size: 96, color: NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1), bold: true)
    centered("Understand every gigabyte on your Mac.", y: 167, size: 34,
             color: NSColor(srgbRed: 110 / 255, green: 110 / 255, blue: 115 / 255, alpha: 1))
    centered("reclaimac.com", y: 66, size: 26, color: blue, bold: true)
}

print("Exported app, favicon, touch, web app, and social icons from the approved source.")
