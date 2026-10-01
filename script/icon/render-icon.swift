// Renders the spyx app icon from its SVG into every size the asset
// catalogue wants, pixel for pixel — no scaling of one big bitmap.
//
//   swift script/icon/render-icon.swift docs/brand/halftone-iris \
//       Sources/LidEffort/Resources/Assets.xcassets/AppIcon.appiconset
//
// The logo itself — the halftone iris — lives in docs/brand/halftone-iris.
// Up to 64 pixels it draws AppIcon-small.svg instead — the same halftone at
// half the density: the full one's dots blur there into a pale grey ring.
import AppKit

let args = CommandLine.arguments.dropFirst()
guard args.count == 2,
      let full = NSImage(contentsOfFile: args.first! + "/AppIcon.svg"),
      let small = NSImage(contentsOfFile: args.first! + "/AppIcon-small.svg") else {
    print("usage: render-icon.swift <brand dir with AppIcon.svg and AppIcon-small.svg> <out-dir>")
    exit(1)
}
let outDir = args.last!

// Point size and scale, as the catalogue names them.
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    (pixels <= 64 ? small : full).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("wrote \(name) (\(pixels)px)")
}
