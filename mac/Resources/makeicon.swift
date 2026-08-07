// Generates Tides.icns from code, so the icon is reproducible and tweakable.
//
// Design: the app's own chart, reduced to its essentials. Teal ground, an off-white
// tide curve with the sage fill beneath it, and one amber dot on the crest, which is
// exactly how a high tide is marked everywhere else in the app. No text, nothing that
// disappears below 32px.
//
//   swift makeicon.swift && iconutil -c icns Tides.iconset -o AppIcon.icns

import Cocoa

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func hex(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
let tealTop    = hex(0x2F, 0x5A, 0x66)   // sky
let tealBottom = hex(0x21, 0x41, 0x4A)
let water      = hex(0x5E, 0x92, 0x8E)   // distinctly lighter so the waterline reads
let paper      = hex(0xF8, 0xF8, 0xF5)
let amber      = hex(0xE0, 0x91, 0x32)

/// Curve height at horizontal fraction t (0...1), in rect-local coordinates.
///
/// Two superposed components, semidiurnal plus diurnal, so the crests come out
/// unequal. That is the diurnal inequality the whole app is about, and it also stops
/// the silhouette reading as a symmetrical hill.
func waveY(_ t: CGFloat, _ h: CGFloat) -> CGFloat {
    let cy = h * 0.44, amp = h * 0.185
    let theta = 2 * .pi * 1.55 * t - 1.06 * .pi
    let semi = sin(theta)
    let diurnal = sin(theta / 2 + 0.55)
    return cy + amp * (0.78 * semi + 0.42 * diurnal)
}

/// The point on the curve lying midway in height between the tallest crest and the
/// trough beside it, i.e. mid-tide. Prefers the falling limb after the crest, which
/// reads as an ebbing tide; falls back to the rising limb if the crest sits so close
/// to the right edge that no trough follows it on canvas.
func midTidePoint(_ pts: [CGPoint]) -> CGPoint? {
    guard pts.count > 4, let ci = pts.indices.max(by: { pts[$0].y < pts[$1].y }) else { return nil }

    // Walk away from the crest until the curve turns back upward; the last index
    // before it turns is the trough. Running off the canvas means there isn't one.
    func trough(step: Int) -> Int? {
        var i = ci + step, last = ci
        while i >= 0 && i < pts.count {
            if pts[i].y > pts[last].y { return last == ci ? nil : last }
            last = i; i += step
        }
        return nil
    }
    guard let ti = trough(step: 1) ?? trough(step: -1) else { return nil }

    let target = (pts[ci].y + pts[ti].y) / 2
    let lo = min(ci, ti), hi = max(ci, ti)
    return pts[lo...hi].min(by: { abs($0.y - target) < abs($1.y - target) })
}

func drawIcon(_ px: Int, fullBleed: Bool = false) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // Apple's macOS icon grid: the rounded square occupies 824/1024 of the canvas,
    // corner radius 185/1024, leaving the surrounding padding the system expects.
    let inset = fullBleed ? 0 : s * 100.0 / 1024.0
    let rect = CGRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let radius = fullBleed ? 0 : s * 185.0 / 1024.0
    let body = fullBleed
        ? CGPath(rect: rect, transform: nil)
        : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [tealTop, tealBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY), options: [])

    // Sample the curve across the full width of the rounded square.
    let steps = max(96, px)
    var pts: [CGPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        pts.append(CGPoint(x: rect.minX + t * rect.width,
                           y: rect.minY + waveY(t, rect.height)))
    }

    // Solid lighter teal beneath the curve: the waterline has to survive 16px,
    // and a translucent wash against a similar background does not.
    let fill = CGMutablePath()
    fill.move(to: CGPoint(x: rect.minX, y: rect.minY))
    fill.addLine(to: pts[0])
    for p in pts.dropFirst() { fill.addLine(to: p) }
    fill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    fill.closeSubpath()
    ctx.addPath(fill); ctx.setFillColor(water); ctx.fillPath()

    // The curve itself.
    let line = CGMutablePath()
    line.move(to: pts[0])
    for p in pts.dropFirst() { line.addLine(to: p) }
    ctx.addPath(line)
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(max(1.2, rect.height * 0.062))
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()

    // Amber dot marking the current water level. Deliberately off the crest: sitting
    // on the peak read as a high-tide marker, whereas mid-way down the falling limb
    // reads as "where the tide is right now", which is what the app is for.
    if let dot = midTidePoint(pts) {
        let r = max(1.6, rect.height * 0.072)
        ctx.setFillColor(amber)
        ctx.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: 2*r, height: 2*r))
        // A thin teal ring keeps the dot readable where it sits on the pale curve.
        ctx.setStrokeColor(tealBottom)
        ctx.setLineWidth(max(0.8, rect.height * 0.022))
        ctx.strokeEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: 2*r, height: 2*r))
    }
    ctx.restoreGState()

    return ctx.makeImage()!
}

let fm = FileManager.default
let dir = URL(fileURLWithPath: "Tides.iconset")
try? fm.removeItem(at: dir)
try! fm.createDirectory(at: dir, withIntermediateDirectories: true)

// iconset filenames the packager expects: each logical size at 1x and 2x.
let want: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
var cache: [Int: CGImage] = [:]
for (name, px) in want {
    let img = cache[px] ?? drawIcon(px)
    cache[px] = img
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: dir.appendingPathComponent("\(name).png"))
}
print("wrote \(want.count) images into Tides.iconset")


// iOS icons: square, full bleed, no alpha. The system applies the rounded mask, so
// baking one in would show a dark halo behind the corners.
let iosDir = URL(fileURLWithPath: "../../ios/Resources")
try? fm.createDirectory(at: iosDir, withIntermediateDirectories: true)
let iosSizes: [(String, Int)] = [
    ("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180),
    ("AppIcon76x76@2x", 152), ("AppIcon83.5x83.5@2x", 167),
    ("AppIcon40x40@2x", 80), ("AppIcon40x40@3x", 120),
    ("AppIcon29x29@2x", 58), ("AppIcon29x29@3x", 87),
    ("AppIcon1024", 1024),
]
for (name, px) in iosSizes {
    let img = drawIcon(px, fullBleed: true)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iosDir.appendingPathComponent("\(name).png"))
}
print("wrote \(iosSizes.count) iOS icons into ios/Resources")


// PWA icons for Windows / Android install. Full bleed like iOS: Android applies its
// own mask, and the artwork is an edge-to-edge scene, so clipped corners read as
// intentional rather than as a cropped logo.
let pwaDir = URL(fileURLWithPath: "../../web/icons")
try? fm.createDirectory(at: pwaDir, withIntermediateDirectories: true)
for (name, px) in [("icon-192", 192), ("icon-512", 512), ("apple-touch-icon", 180)] {
    let img = drawIcon(px, fullBleed: true)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: pwaDir.appendingPathComponent("\(name).png"))
}
print("wrote 3 PWA icons into web/icons")
