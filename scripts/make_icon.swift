// Generates AppIcon.iconset/ for SayCtrl: warm paper squircle, three ink bars
// rising, then the ember arrow — the app mark, flat, no gradients. Run with
// `swift make_icon.swift`, then
// `iconutil -c icns AppIcon.iconset -o AppIcon.icns` (build.sh does both).
//
// The geometry below is the same 256 grid as Theme.drawMark in the app and the
// website's public/appicon.svg. This script is standalone — it cannot import
// the app's sources — so the numbers are repeated here on purpose. Change one,
// change all three.
import AppKit

func drawIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let paper = NSColor(calibratedRed: 0.969, green: 0.961, blue: 0.941, alpha: 1) // #F7F5F0
    let ink   = NSColor(calibratedRed: 0.125, green: 0.118, blue: 0.102, alpha: 1) // #201E1A
    let ember = NSColor(calibratedRed: 0.820, green: 0.294, blue: 0.122, alpha: 1) // #D14B1F

    // Squircle background with the standard macOS icon margin.
    let inset = 0.065 * s
    let bgRect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 0.2 * s, yRadius: 0.2 * s)
    paper.setFill()
    bg.fill()
    // Hairline edge so the paper reads on white backgrounds.
    ink.withAlphaComponent(0.10).setStroke()
    bg.lineWidth = max(1, 0.008 * s)
    bg.stroke()

    // The app mark, on the 256 grid, inset to 0.88 so the badge keeps the air
    // an icon wants. Everything is symmetric about y128, so AppKit's bottom-up
    // y needs no flip.
    let barX: [CGFloat] = [50, 88, 126]
    let barHalf: [CGFloat] = [37.5, 64.5, 84]
    let stroke: CGFloat = 24
    let arrow: [(CGFloat, CGFloat)] = [(158, 71), (158, 185), (206, 128)]
    let join: CGFloat = 12

    let inset88: CGFloat = 0.88
    let unit = s / 256
    func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: (128 + (x - 128) * inset88) * unit,
                y: (128 + (y - 128) * inset88) * unit)
    }
    let barW = stroke * inset88 * unit

    ink.setFill()
    for (i, x) in barX.enumerated() {
        let top = at(x - stroke / 2, 128 - barHalf[i])
        let bar = NSRect(x: top.x, y: top.y, width: barW, height: barHalf[i] * 2 * inset88 * unit)
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
    }

    // Filled and then outlined in its own colour, which is what rounds the
    // arrow's three corners without shrinking it.
    let wedge = NSBezierPath()
    wedge.move(to: at(arrow[0].0, arrow[0].1))
    wedge.line(to: at(arrow[1].0, arrow[1].1))
    wedge.line(to: at(arrow[2].0, arrow[2].1))
    wedge.close()
    wedge.lineJoinStyle = .round
    wedge.lineWidth = join * inset88 * unit
    ember.setFill()
    wedge.fill()
    ember.setStroke()
    wedge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = drawIcon(px: px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("Wrote AppIcon.iconset (\(sizes.count) images)")
