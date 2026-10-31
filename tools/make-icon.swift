// Renders the 1024px app icon: orange gradient, terminal prompt ">_" with a phone-signal arc.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let colors = [NSColor(red: 0.90, green: 0.54, blue: 0.42, alpha: 1).cgColor, NSColor(red: 0.72, green: 0.34, blue: 0.20, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setLineWidth(84)
ctx.move(to: CGPoint(x: 270, y: 680)); ctx.addLine(to: CGPoint(x: 470, y: 512)); ctx.addLine(to: CGPoint(x: 270, y: 344))
ctx.strokePath()
ctx.move(to: CGPoint(x: 560, y: 340)); ctx.addLine(to: CGPoint(x: 760, y: 340)); ctx.strokePath()
ctx.setLineWidth(44)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
for (i, r) in [110.0, 190.0].enumerated() {
  ctx.addArc(center: CGPoint(x: 660, y: 560), radius: r, startAngle: .pi * 0.15, endAngle: .pi * 0.55, clockwise: false)
  ctx.setAlpha(i == 0 ? 1 : 0.7); ctx.strokePath()
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
