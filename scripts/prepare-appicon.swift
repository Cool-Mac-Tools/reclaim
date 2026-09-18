import AppKit

// Full-canvas artwork for the macOS asset catalog. Keep the approved, rounded
// website artwork and legacy ICNS separate; macOS supplies the modern mask.
let fm = FileManager.default
let sourcePath = "Resources/reclaim-icon-full-canvas.png"
guard let source = NSImage(contentsOfFile: sourcePath) else { fatalError("Missing full-canvas icon") }
let root = "Resources/Assets.xcassets"
let set = root + "/AppIcon.appiconset"
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: set + "/" + name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
for (path, json) in [(root + "/Contents.json", ["info": info]),
                     (set + "/Contents.json", ["images": images, "info": info])] {
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path))
}
print("Prepared all macOS app icon sizes.")
