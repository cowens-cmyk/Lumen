import AppKit
import CoreGraphics

// Draws the Lumen icon: a glowing 16:9 screen with lyric lines, light spilling from it.
// Usage: swift Tools/make_icon.swift out.png
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: rounded square inset ~10%
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = CGPath(roundedRect: rect, cornerWidth: 184, cornerHeight: 184, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(bg); ctx.setFillColor(CGColor(red: 0.08, green: 0.07, blue: 0.2, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.27, green: 0.22, blue: 0.62, alpha: 1),
                                                 CGColor(red: 0.05, green: 0.05, blue: 0.16, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Warm glow behind the screen
let glow = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1.0, green: 0.78, blue: 0.35, alpha: 0.75),
                                                 CGColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])

// Light beam falling from the screen to the floor
ctx.saveGState()
let beam = CGMutablePath()
beam.move(to: CGPoint(x: 300, y: 420)); beam.addLine(to: CGPoint(x: 724, y: 420))
beam.addLine(to: CGPoint(x: 900, y: 100)); beam.addLine(to: CGPoint(x: 124, y: 100)); beam.closeSubpath()
ctx.addPath(beam); ctx.clip()
let beamGrad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 0.85, blue: 0.55, alpha: 0.35),
                                                     CGColor(red: 1, green: 0.85, blue: 0.55, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(beamGrad, start: CGPoint(x: 512, y: 420), end: CGPoint(x: 512, y: 120), options: [])
ctx.restoreGState()

// The screen
let screen = CGRect(x: 232, y: 420, width: 560, height: 315)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: CGColor(red: 1, green: 0.8, blue: 0.45, alpha: 0.9))
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 28, cornerHeight: 28, transform: nil))
ctx.setFillColor(CGColor(red: 1.0, green: 0.97, blue: 0.9, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: 18, dy: 18), cornerWidth: 16, cornerHeight: 16, transform: nil))
ctx.setFillColor(CGColor(red: 0.1, green: 0.09, blue: 0.24, alpha: 1)); ctx.fillPath()

// Lyric lines
ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.85, alpha: 1))
for (w, y) in [(360.0, 615.0), (300.0, 545.0)] {
    let r = CGRect(x: 512 - w / 2, y: y, width: w, height: 30)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 15, cornerHeight: 15, transform: nil)); ctx.fillPath()
}
// Accent chord marks above the lines (the stage display's Nashville numbers)
ctx.setFillColor(CGColor(red: 0.35, green: 0.75, blue: 1, alpha: 1))
for x in [352.0, 470.0, 610.0] { ctx.fillEllipse(in: CGRect(x: x, y: 660, width: 26, height: 26)) }
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
