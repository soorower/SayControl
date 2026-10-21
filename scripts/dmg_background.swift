// Draws the backdrop of the install window (design/dmg-window-options.html,
// option A): warm paper, each icon on a soft raised pad, a dotted ember path
// arcing from the app into the Applications folder, and what to do, set
// clear of the bar Finder lays over the window's foot. Written as a
// two-resolution TIFF so it is crisp on Retina and plain displays alike.
//
//   swift scripts/dmg_background.swift <out.tiff> <width> <height> <appX> <folderX> <iconY>
//
// The icon centres come from make_dmg.sh, the same numbers dmg_settings.py
// gives Finder, so the pads, the path and the tags land on the icons.
//
// Finder writes each icon's name itself, black in Light Mode and white in
// Dark Mode, on whatever is behind it. A quiet taupe tag sits under each
// name so both read; nothing else of ours goes where a name is drawn.
import Cocoa

let args = CommandLine.arguments
guard args.count == 7, let w = Double(args[2]), let h = Double(args[3]),
      let appX = Double(args[4]), let folderX = Double(args[5]), let iconY = Double(args[6]) else {
    FileHandle.standardError.write("usage: dmg_background.swift out.tiff width height appX folderX iconY\n".data(using: .utf8)!)
    exit(1)
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let ember = rgb(0xC4451A), emberHot = rgb(0xE5501F)
let ink = rgb(0x1E1B16), muted = rgb(0x5F584E)
let tagFill = rgb(0x978C7F)   // black text 6.4:1 on it, white 3.3:1

// Finder's coordinates run top-down from the window's top-left; ours run
// bottom-up. Every number below is written Finder's way and flipped here.
func up(_ y: Double) -> Double { h - y }

/// Where Finder centres a 13 pt name under a 128 pt icon centred at iconY
/// (measured off a real window: 84 pt below the icon's centre).
let nameY = iconY + 84

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    // The rep is sized in points and backed by scale× pixels; the context
    // made from it already draws scaled.
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext

    // Paper, lit from the top: a wide soft glow fading to a warmer cream.
    rgb(0xEFE7DA).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    cg.saveGState()
    cg.translateBy(x: w / 2, y: h)
    cg.scaleBy(x: 1, y: 0.75)
    let paper = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0xFFFDF8).cgColor, rgb(0xF7F2E9).cgColor, rgb(0xEFE7DA).cgColor] as CFArray,
                           locations: [0, 0.6, 1])!
    cg.drawRadialGradient(paper, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: w * 0.7,
                          options: [.drawsAfterEndLocation])
    cg.restoreGState()

    // A raised pad under each icon, its name inside it.
    for x in [appX, folderX] {
        let side = 196.0, radius = 48.0
        let rect = NSRect(x: x - side / 2, y: up(iconY + 17) - side / 2, width: side, height: side)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x78461E, 0.26).cgColor)
        rgb(0xFFFFFF).setFill()
        shape.fill()
        cg.restoreGState()
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: rgb(0x78461E, 0.08).cgColor)
        shape.fill()
        cg.restoreGState()
        NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xFBF7F0))!.draw(in: shape, angle: -90)
        rgb(0x1E1B16, 0.07).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // The tag the name is written on.
        let tag = NSRect(x: x - 56, y: up(nameY) - 12, width: 112, height: 24)
        tagFill.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 12, yRadius: 12).fill()
    }

    // The way in: a dotted arc from the app's pad over into the folder,
    // fading up from a faint start to full ember at the head.
    let start = NSPoint(x: appX + 104, y: up(iconY - 15))
    let end = NSPoint(x: folderX - 70, y: up(iconY - 29))
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: NSPoint(x: appX + 150, y: up(iconY - 71)),
              controlPoint2: NSPoint(x: folderX - 96, y: up(iconY - 71)))
    cg.saveGState()
    cg.addPath(arc.cgPath)
    cg.setLineWidth(4)
    cg.setLineCap(.round)
    cg.setLineDash(phase: 0, lengths: [0.1, 11])
    cg.replacePathWithStrokedPath()
    cg.clip()
    let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [emberHot.withAlphaComponent(0.35).cgColor, ember.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(fade, start: start, end: end, options: [])
    cg.restoreGState()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x, y: end.y + 18))
    head.line(to: NSPoint(x: end.x + 1, y: end.y - 1))
    head.line(to: NSPoint(x: end.x - 17, y: end.y + 6))
    head.lineWidth = 4.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    ember.setStroke()
    head.stroke()

    // What to do, under the pads with room to breathe, and all of it above
    // y 400: macOS 26's Finder lays a bar over the window's last ~28 pt,
    // and make_dmg.sh makes the window tall enough that 400 pt show.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let base = NSFont.systemFont(ofSize: 23, weight: .semibold)
    let serif = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 23) } ?? base
    NSAttributedString(string: "Drag SayControl into Applications", attributes: [
        .font: serif, .foregroundColor: ink, .paragraphStyle: style, .kern: -0.2,
    ]).draw(in: NSRect(x: 0, y: up(314) - 32, width: w, height: 32))
    NSAttributedString(string: "Then open it from Applications. It walks you through the rest.", attributes: [
        .font: NSFont.systemFont(ofSize: 14), .foregroundColor: muted, .paragraphStyle: style,
    ]).draw(in: NSRect(x: 0, y: up(354) - 20, width: w, height: 20))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: w, height: h))
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
guard let tiff = image.tiffRepresentation(using: .lzw, factor: 0) else { exit(1) }
try! tiff.write(to: URL(fileURLWithPath: args[1]))
