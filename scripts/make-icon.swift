import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1),
    NSColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
])!.draw(in: tilePath, angle: -90)
NSColor.white.withAlphaComponent(0.08).setStroke()
tilePath.lineWidth = 6
tilePath.stroke()

let center = NSPoint(x: size / 2, y: size / 2)
let ringRadius: CGFloat = 250
let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
ring.lineWidth = 34
NSColor.white.withAlphaComponent(0.92).setStroke()
ring.stroke()

let dotRadius: CGFloat = 172
let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
NSColor(red: 0.94, green: 0.27, blue: 0.37, alpha: 1).setFill()
dot.fill()

image.unlockFocus()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: output)
