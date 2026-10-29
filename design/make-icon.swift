// Renders the Galaxy Bridge app icon. Usage: swift design/make-icon.swift <output.png> [size]
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: make-icon.swift <output.png> [size]") }
let size = CGFloat(Double(args.count > 2 ? args[2] : "1024") ?? 1024)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = size / 1024

// Background: full-bleed gradient (iOS applies its own corner mask).
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: 0.27, green: 0.30, blue: 0.95, alpha: 1),
    CGColor(red: 0.14, green: 0.74, blue: 0.84, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft highlight.
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.22), CGColor(red: 1, green: 1, blue: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330 * s, y: 760 * s), startRadius: 0,
                       endCenter: CGPoint(x: 330 * s, y: 760 * s), endRadius: 620 * s, options: [])

let center = CGPoint(x: 470 * s, y: 540 * s)

// Link arcs to the upper right, suggesting the phone connection.
ctx.setLineCap(.round)
for (i, r) in [300.0, 375.0, 450.0].enumerated() {
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85 - Double(i) * 0.25))
    ctx.setLineWidth(34 * s)
    ctx.addArc(center: center, radius: CGFloat(r) * s, startAngle: .pi * 0.12, endAngle: .pi * 0.38, clockwise: false)
    ctx.strokePath()
}

// Watch body with drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 48 * s,
              color: CGColor(red: 0.05, green: 0.06, blue: 0.25, alpha: 0.45))
ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - 250 * s, y: center.y - 250 * s, width: 500 * s, height: 500 * s))
ctx.restoreGState()

// Bezel ring and ticks.
ctx.setStrokeColor(CGColor(red: 0.85, green: 0.88, blue: 1, alpha: 1))
ctx.setLineWidth(22 * s)
ctx.strokeEllipse(in: CGRect(x: center.x - 239 * s, y: center.y - 239 * s, width: 478 * s, height: 478 * s))
for i in 0..<60 {
    let major = i % 5 == 0
    let a = CGFloat(i) * .pi / 30
    let r1: CGFloat = (major ? 172 : 190) * s, r2: CGFloat = 208 * s
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: major ? 0.95 : 0.4))
    ctx.setLineWidth((major ? 12 : 5) * s)
    ctx.move(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * r2, y: center.y + sin(a) * r2))
    ctx.strokePath()
}

// Teal progress arc inside, like the health ring on the dashboard.
ctx.setStrokeColor(CGColor(red: 0.18, green: 0.86, blue: 0.9, alpha: 1))
ctx.setLineWidth(30 * s)
ctx.addArc(center: center, radius: 128 * s, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.45, clockwise: true)
ctx.strokePath()

// Heart in the middle.
let heart = CGMutablePath()
let h: CGFloat = 70 * s
heart.move(to: CGPoint(x: center.x, y: center.y - h * 0.9))
heart.addCurve(to: CGPoint(x: center.x - h, y: center.y + h * 0.25),
               control1: CGPoint(x: center.x - h * 0.4, y: center.y - h * 0.45),
               control2: CGPoint(x: center.x - h, y: center.y - h * 0.3))
heart.addArc(center: CGPoint(x: center.x - h * 0.5, y: center.y + h * 0.3), radius: h * 0.5,
             startAngle: .pi, endAngle: 0, clockwise: true)
heart.addArc(center: CGPoint(x: center.x + h * 0.5, y: center.y + h * 0.3), radius: h * 0.5,
             startAngle: .pi, endAngle: 0, clockwise: true)
heart.addCurve(to: CGPoint(x: center.x, y: center.y - h * 0.9),
               control1: CGPoint(x: center.x + h, y: center.y - h * 0.3),
               control2: CGPoint(x: center.x + h * 0.4, y: center.y - h * 0.45))
ctx.addPath(heart)
ctx.setFillColor(CGColor(red: 1, green: 0.32, blue: 0.42, alpha: 1))
ctx.fillPath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
