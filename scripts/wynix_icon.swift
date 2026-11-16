// Renders the WYNIX app icon: metallic pink W (#E05A83) on a dark tile, matching the website logo.
import AppKit
let out = CommandLine.arguments[1]
let s: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let k = s / 64 * 0.8, o = s * 0.1   // macOS icon grid: 80% tile, 10% margin
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255)/255, green: CGFloat((h >> 8) & 255)/255, blue: CGFloat(h & 255)/255, alpha: a)
}
// Tile: near-black with a soft top light.
let tile = CGPath(roundedRect: CGRect(x: o, y: o, width: 64*k, height: 64*k), cornerWidth: 14*k, cornerHeight: 14*k, transform: nil)
cg.saveGState(); cg.addPath(tile); cg.clip()
cg.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [rgb(0x26282B), rgb(0x111214)] as CFArray, locations: [0, 1])!,
                      start: CGPoint(x: 0, y: s - o), end: CGPoint(x: 0, y: o), options: [])
cg.drawRadialGradient(CGGradient(colorsSpace: nil, colors: [rgb(0xE05A83, 0.28), rgb(0xE05A83, 0)] as CFArray, locations: [0, 1])!,
                      startCenter: CGPoint(x: s/2, y: s/2), startRadius: 0, endCenter: CGPoint(x: s/2, y: s/2), endRadius: s*0.42, options: [])
cg.restoreGState()
// W stroke as an outline, filled with a metallic pink gradient.
let w = CGMutablePath()
let pts: [(CGFloat, CGFloat)] = [(13,24),(21,39),(32,24),(43,39),(51,24)]
for (i, (x, y)) in pts.enumerated() {
    let p = CGPoint(x: o + x*k, y: o + (64 - y)*k)
    i == 0 ? w.move(to: p) : w.addLine(to: p)
}
let stroke = w.copy(strokingWithWidth: 7*k, lineCap: .round, lineJoin: .round, miterLimit: 10)
cg.saveGState()
cg.setShadow(offset: .zero, blur: 40, color: rgb(0xE05A83, 0.55))
cg.addPath(stroke); cg.setFillColor(rgb(0xE05A83)); cg.fillPath()
cg.restoreGState()
cg.saveGState(); cg.addPath(stroke); cg.clip()
let metal = CGGradient(colorsSpace: nil,
    colors: [rgb(0xC94470), rgb(0xE05A83), rgb(0xFFD3E0), rgb(0xE05A83), rgb(0xF08AA8), rgb(0xFFE4EC), rgb(0xD24D77), rgb(0xC94470)] as CFArray,
    locations: [0, 0.16, 0.27, 0.4, 0.52, 0.6, 0.75, 1])!
cg.drawLinearGradient(metal, start: CGPoint(x: o, y: s - o), end: CGPoint(x: s - o, y: o), options: [])
cg.restoreGState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
