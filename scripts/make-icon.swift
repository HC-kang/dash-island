// Draws the app icon and writes Sources/Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
// Motif: the notch island (black pill with a glowing rim) above a three-ring
// usage gauge in the vendor colors, with the red burn needle.
import AppKit

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)  // draw in 1024-point space; y grows up

    // Squircle body (Big Sur grid: 824 pt body inside 1024 canvas).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(squircle); ctx.setFillColor(rgb(12, 14, 18)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(34, 38, 46), rgb(10, 12, 15)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Notch pill hanging from the top edge, with a warm glowing rim underneath.
    let pill = CGRect(x: 312, y: 780, width: 400, height: 170)
    let pillPath = CGPath(roundedRect: pill, cornerWidth: 70, cornerHeight: 70, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: rgb(255, 92, 40, 0.85))
    ctx.addPath(pillPath); ctx.setStrokeColor(rgb(255, 120, 60, 0.9)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(pillPath); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
    // A tiny live dot on the pill.
    ctx.setFillColor(rgb(61, 214, 140)); ctx.fillEllipse(in: CGRect(x: 640, y: 830, width: 26, height: 26))

    // Three-ring gauge: track + value arc per ring (270° dial opening at the bottom).
    let center = CGPoint(x: 512, y: 430)
    let rings: [(radius: CGFloat, width: CGFloat, color: CGColor, value: CGFloat)] = [
        (250, 44, rgb(204, 120, 92), 0.72),   // Claude
        (186, 40, rgb(90, 168, 240), 0.48),   // Codex
        (126, 36, rgb(167, 139, 250), 0.30),  // Grok
    ]
    let startAngle = CGFloat.pi * 1.25  // 225°: lower-left, sweeping clockwise
    let sweep = CGFloat.pi * 1.5
    ctx.setLineCap(.round)
    for ring in rings {
        ctx.setLineWidth(ring.width)
        ctx.setStrokeColor(rgb(255, 255, 255, 0.07))
        ctx.addArc(center: center, radius: ring.radius, startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
        ctx.strokePath()
        ctx.setStrokeColor(ring.color)
        ctx.addArc(center: center, radius: ring.radius, startAngle: startAngle,
                   endAngle: startAngle - sweep * ring.value, clockwise: true)
        ctx.strokePath()
    }

    // Burn needle from the hub toward the upper right.
    let angle = CGFloat.pi * 0.28
    let tip = CGPoint(x: center.x + cos(angle) * 230, y: center.y + sin(angle) * 230)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: rgb(255, 60, 50, 0.7))
    ctx.setStrokeColor(rgb(255, 70, 60)); ctx.setLineWidth(14)
    ctx.move(to: center); ctx.addLine(to: tip); ctx.strokePath()
    ctx.restoreGState()
    ctx.setFillColor(rgb(235, 238, 243)); ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
    ctx.restoreGState()
    return ctx.makeImage()!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let rep = NSBitmapImageRep(cgImage: draw(size: base * scale))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = "Sources/Resources/AppIcon.icns"
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
// Also keep a preview PNG for README/docs.
try! NSBitmapImageRep(cgImage: draw(size: 512)).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Sources/Resources/AppIcon-preview.png"))
print("wrote \(out)")
