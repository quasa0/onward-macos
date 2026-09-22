import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let p = CGFloat(pixels), inset = p * 0.07
    let shape = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: p - 2 * inset, height: p - 2 * inset), xRadius: p * 0.2, yRadius: p * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.26, green: 0.55, blue: 0.43, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.25, blue: 0.20, alpha: 1))!.draw(in: shape, angle: -65)
    let ring = NSBezierPath(ovalIn: NSRect(x: p * 0.25, y: p * 0.25, width: p * 0.50, height: p * 0.50))
    NSColor.white.withAlphaComponent(0.22).setStroke(); ring.lineWidth = p * 0.018; ring.stroke()
    let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: p * 0.33, y: p * 0.32)); arrow.line(to: NSPoint(x: p * 0.66, y: p * 0.65)); arrow.move(to: NSPoint(x: p * 0.40, y: p * 0.65)); arrow.line(to: NSPoint(x: p * 0.66, y: p * 0.65)); arrow.line(to: NSPoint(x: p * 0.66, y: p * 0.39))
    arrow.lineWidth = p * 0.065; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; NSColor.white.setStroke(); arrow.stroke()
    image.unlockFocus()
    let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try data.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
