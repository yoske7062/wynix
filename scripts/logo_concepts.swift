// Renders 5 Steamy app-icon concepts plus a labeled comparison sheet.
// Usage: swift scripts/logo_concepts.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "concepts")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rgb = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let accent = c(0, 0.98, 0.54)
let white = c(0.95, 0.96, 0.97)

func canvas(_ size: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.current = nil
    return rep
}

/// macOS-style squircle tile with depth: graphite gradient, top sheen, hairline edge.
func tile(_ ctx: CGContext, top: CGColor = c(0.17, 0.18, 0.21), bottom: CGColor = c(0.05, 0.05, 0.07)) -> CGPath {
    let path = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: c(0, 0, 0, 0.45))
    ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [top, bottom] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: [c(1, 1, 1, 0.07), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 1000), startRadius: 0, endCenter: CGPoint(x: 512, y: 1000), endRadius: 700, options: [])
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(c(1, 1, 1, 0.08)); ctx.setLineWidth(3); ctx.strokePath()
    return path
}

func glow(_ ctx: CGContext, _ color: CGColor, _ blur: CGFloat, _ body: () -> Void) {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: blur, color: color); body(); ctx.restoreGState()
}

// 1. Vapor S: a single bold S stroke whose top end lifts off as steam.
let vaporS = canvas(1024) { ctx in
    _ = tile(ctx)
    let s = CGMutablePath()
    s.move(to: CGPoint(x: 352, y: 300))
    s.addCurve(to: CGPoint(x: 512, y: 250), control1: CGPoint(x: 400, y: 262), control2: CGPoint(x: 450, y: 250))
    s.addCurve(to: CGPoint(x: 660, y: 380), control1: CGPoint(x: 600, y: 250), control2: CGPoint(x: 660, y: 300))
    s.addCurve(to: CGPoint(x: 512, y: 500), control1: CGPoint(x: 660, y: 460), control2: CGPoint(x: 590, y: 480))
    s.addCurve(to: CGPoint(x: 370, y: 620), control1: CGPoint(x: 430, y: 520), control2: CGPoint(x: 370, y: 545))
    s.addCurve(to: CGPoint(x: 512, y: 740), control1: CGPoint(x: 370, y: 700), control2: CGPoint(x: 435, y: 740))
    s.addCurve(to: CGPoint(x: 650, y: 700), control1: CGPoint(x: 570, y: 740), control2: CGPoint(x: 620, y: 725))
    ctx.addPath(s); ctx.setStrokeColor(white); ctx.setLineWidth(78); ctx.setLineCap(.round); ctx.strokePath()
    // steam: two short wisps rising off the top terminal
    ctx.setLineWidth(22)
    for (i, x) in [612.0, 682.0].enumerated() {
        let w = CGMutablePath()
        w.move(to: CGPoint(x: x, y: 770 + Double(i) * 10))
        w.addCurve(to: CGPoint(x: x + 10, y: 860), control1: CGPoint(x: x - 30, y: 800), control2: CGPoint(x: x + 40, y: 830))
        ctx.addPath(w)
        ctx.setStrokeColor(i == 0 ? c(0.95, 0.96, 0.97, 0.55) : accent)
        ctx.strokePath()
    }
}

// 2. Bottle + Play: glass bottle silhouette carrying a play triangle.
let bottlePlay = canvas(1024) { ctx in
    _ = tile(ctx)
    let b = CGMutablePath()
    b.move(to: CGPoint(x: 392, y: 210)); b.addLine(to: CGPoint(x: 632, y: 210))
    b.addQuadCurve(to: CGPoint(x: 692, y: 270), control: CGPoint(x: 692, y: 210))
    b.addLine(to: CGPoint(x: 692, y: 540))
    b.addCurve(to: CGPoint(x: 566, y: 668), control1: CGPoint(x: 692, y: 620), control2: CGPoint(x: 566, y: 610))
    b.addLine(to: CGPoint(x: 566, y: 790)); b.addLine(to: CGPoint(x: 458, y: 790)); b.addLine(to: CGPoint(x: 458, y: 668))
    b.addCurve(to: CGPoint(x: 332, y: 540), control1: CGPoint(x: 458, y: 610), control2: CGPoint(x: 332, y: 620))
    b.addLine(to: CGPoint(x: 332, y: 270))
    b.addQuadCurve(to: CGPoint(x: 392, y: 210), control: CGPoint(x: 332, y: 210))
    b.closeSubpath()
    ctx.addPath(b); ctx.setFillColor(white); ctx.fillPath()
    let play = CGMutablePath()
    play.move(to: CGPoint(x: 465, y: 315)); play.addLine(to: CGPoint(x: 465, y: 495)); play.addLine(to: CGPoint(x: 600, y: 405)); play.closeSubpath()
    ctx.addPath(play); ctx.setFillColor(c(0.07, 0.07, 0.09)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 446, y: 790, width: 132, height: 40), cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(accent); ctx.fillPath()
}

// 3. Panes: four window panes floating in perspective, one lit in accent.
let panes = canvas(1024) { ctx in
    _ = tile(ctx)
    ctx.saveGState()
    var t = CGAffineTransform(translationX: 512, y: 512).rotated(by: -.pi / 12).scaledBy(x: 1, y: 0.92)
    let size: CGFloat = 150, gap: CGFloat = 28
    for row in 0..<2 {
        for col in 0..<2 {
            let r = CGRect(x: CGFloat(col) * (size + gap) - size - gap / 2, y: CGFloat(row) * (size + gap) - size - gap / 2, width: size, height: size)
            let p = CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: &t)
            if row == 1 && col == 1 {
                glow(ctx, c(0, 0.98, 0.54, 0.6), 50) { ctx.addPath(p); ctx.setFillColor(accent); ctx.fillPath() }
            } else {
                ctx.addPath(p); ctx.setFillColor(c(0.95, 0.96, 0.97, row == 0 && col == 0 ? 0.55 : 0.9)); ctx.fillPath()
            }
        }
    }
    ctx.restoreGState()
}

// 4. Capri mark: the slanted bandana bar with notch and a single glowing eye.
let capri = canvas(1024) { ctx in
    _ = tile(ctx, top: c(0.10, 0.10, 0.12), bottom: c(0.02, 0.02, 0.03))
    let band = CGMutablePath()
    band.addLines(between: [CGPoint(x: 210, y: 610), CGPoint(x: 470, y: 622), CGPoint(x: 512, y: 548), CGPoint(x: 556, y: 600),
                            CGPoint(x: 820, y: 596), CGPoint(x: 806, y: 418), CGPoint(x: 224, y: 404)])
    band.closeSubpath()
    ctx.addPath(band); ctx.setFillColor(white); ctx.fillPath()
    let eye = CGPoint(x: 340, y: 512)
    ctx.addEllipse(in: CGRect(x: eye.x - 74, y: eye.y - 74, width: 148, height: 148)); ctx.setFillColor(c(0.03, 0.03, 0.04)); ctx.fillPath()
    glow(ctx, c(0, 0.98, 0.54, 0.9), 40) {
        ctx.addEllipse(in: CGRect(x: eye.x - 44, y: eye.y - 44, width: 88, height: 88)); ctx.setFillColor(accent); ctx.fillPath()
    }
    ctx.addEllipse(in: CGRect(x: eye.x - 14, y: eye.y + 4, width: 22, height: 22)); ctx.setFillColor(c(1, 1, 1, 0.9)); ctx.fillPath()
    let star = CGMutablePath()
    star.move(to: CGPoint(x: 590, y: 470)); star.addQuadCurve(to: CGPoint(x: 700, y: 560), control: CGPoint(x: 690, y: 505))
    star.addQuadCurve(to: CGPoint(x: 760, y: 520), control: CGPoint(x: 705, y: 515))
    star.addQuadCurve(to: CGPoint(x: 675, y: 440), control: CGPoint(x: 700, y: 500))
    star.addQuadCurve(to: CGPoint(x: 590, y: 470), control: CGPoint(x: 680, y: 495))
    ctx.addPath(star); ctx.setFillColor(c(0.03, 0.03, 0.04)); ctx.fillPath()
}

// 5. Rising: three vapor columns of rising height inside a ring, like a level meter.
let rising = canvas(1024) { ctx in
    _ = tile(ctx)
    ctx.addEllipse(in: CGRect(x: 262, y: 262, width: 500, height: 500))
    ctx.setStrokeColor(c(0.95, 0.96, 0.97, 0.16)); ctx.setLineWidth(18); ctx.strokePath()
    ctx.setLineCap(.round); ctx.setLineWidth(64)
    for (i, (x, top)) in [(402.0, 560.0), (512.0, 660.0), (622.0, 610.0)].enumerated() {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: 380))
        p.addCurve(to: CGPoint(x: x, y: top), control1: CGPoint(x: x - 34, y: 450), control2: CGPoint(x: x + 34, y: top - 80))
        ctx.addPath(p)
        if i == 1 {
            glow(ctx, c(0, 0.98, 0.54, 0.6), 40) { ctx.setStrokeColor(accent); ctx.strokePath() }
        } else {
            ctx.setStrokeColor(white); ctx.strokePath()
        }
    }
}

let concepts = [("1 · Vapor S", vaporS), ("2 · Bottle Play", bottlePlay), ("3 · Panes", panes), ("4 · Capri Mark", capri), ("5 · Rising", rising)]
for (i, (_, rep)) in concepts.enumerated() {
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("concept-\(i + 1).png"))
}

// Comparison sheet: each concept large, plus a 64 px (Dock) and 32 px (Finder) preview.
let cell: CGFloat = 420, pad: CGFloat = 40
let sheetW = Int(cell * 5 + pad * 6), sheetH = 640
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sheetW, pixelsHigh: sheetH, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()
for (i, (name, rep)) in concepts.enumerated() {
    let x = pad + CGFloat(i) * (cell + pad)
    let image = NSImage(size: NSSize(width: 1024, height: 1024)); image.addRepresentation(rep)
    image.draw(in: NSRect(x: x, y: 170, width: cell, height: cell))
    image.draw(in: NSRect(x: x + 110, y: 70, width: 64, height: 64))
    image.draw(in: NSRect(x: x + 200, y: 86, width: 32, height: 32))
    (name as NSString).draw(at: NSPoint(x: x + 20, y: 600), withAttributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
}
NSGraphicsContext.current = nil
try! sheet.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("concepts-sheet.png"))
print("Wrote \(outDir.path)")
