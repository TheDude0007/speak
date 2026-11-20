// Renders the Speak app icon (1024px PNG) — usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.16, alpha: 1),
                    NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.40, alpha: 1)])!.draw(in: path, angle: -60)
// waveform bars
let heights: [CGFloat] = [0.22, 0.46, 0.78, 1.0, 0.78, 0.46, 0.22]
let barW: CGFloat = 54, gap: CGFloat = 34
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = size / 2 - total / 2
for (i, h) in heights.enumerated() {
    let bh = 520 * h
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: size / 2 - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2)
    let t = CGFloat(i) / CGFloat(heights.count - 1)
    NSColor(calibratedRed: 0.35 + 0.5 * t, green: 0.85 - 0.3 * t, blue: 1.0, alpha: 1).setFill()
    bar.fill()
    x += barW + gap
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
