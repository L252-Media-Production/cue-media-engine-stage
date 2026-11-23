// Renders the macOS app icon set from cueme-stage-icon-dark.svg. No dependencies: AppKit draws the SVG.
//
//   swift tests/tools/make-app-icon.swift
//
// (from the repo root). Writes Apps/CueMEStage/Resources/Assets.xcassets/AppIcon.appiconset: the ten PNGs and
// Contents.json. Apple's macOS icon grid: the rounded tile is 824 of 1024 px (about 80%), centred on a transparent
// canvas, with a soft drop shadow (black 30%, 12 px down, 24 px blur at 1024; scaled for the other sizes).
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Apps/CueMEStage/Resources/Branding/cueme-stage-icon-dark.svg")
let setURL = root.appendingPathComponent("Apps/CueMEStage/Resources/Assets.xcassets/AppIcon.appiconset")

guard let svg = NSImage(contentsOf: svgURL), svg.isValid else {
    FileHandle.standardError.write("Cannot read \(svgURL.path) (run from the repo root)\n".data(using: .utf8)!)
    exit(1)
}
try FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)

/// One square PNG of `pixels` px.
func render(pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
    )!
    rep.size = NSSize(width: pixels, height: pixels) // 1 pt = 1 px: the file's own pixel size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let tile = 824 * scale
    let origin = (CGFloat(pixels) - tile) / 2
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale) // down
    shadow.shadowBlurRadius = 24 * scale
    shadow.set()
    svg.draw(in: NSRect(x: origin, y: origin, width: tile, height: tile), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: size * scale).write(to: setURL.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: setURL.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) PNGs and Contents.json to \(setURL.path)")
