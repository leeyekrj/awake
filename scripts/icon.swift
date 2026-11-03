import AppKit
let target = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
for side in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let s = CGFloat(side)
    let rect = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.15, alpha: 1).setFill(); path.fill()
    NSColor(calibratedRed: 0.92, green: 0.67, blue: 0.36, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.20, y: s * 0.20, width: s * 0.60, height: s * 0.60)).fill()
    // Original tall, angular mug artwork. No SF Symbol glyph is exported into the app icon.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.scale(by: s / 1024)
    transform.concat()
    let ink = NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.13, alpha: 1)
    ink.setFill(); ink.setStroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 640, y: 562))
    handle.line(to: NSPoint(x: 730, y: 562))
    handle.line(to: NSPoint(x: 730, y: 414))
    handle.line(to: NSPoint(x: 633, y: 382))
    handle.lineWidth = 35; handle.lineJoinStyle = .round; handle.stroke()
    let mug = NSBezierPath()
    mug.move(to: NSPoint(x: 333, y: 588))
    mug.line(to: NSPoint(x: 663, y: 588))
    mug.line(to: NSPoint(x: 625, y: 332))
    mug.curve(to: NSPoint(x: 385, y: 332), controlPoint1: NSPoint(x: 578, y: 300), controlPoint2: NSPoint(x: 431, y: 300))
    mug.close(); mug.fill()
    let saucer = NSBezierPath()
    saucer.move(to: NSPoint(x: 296, y: 277)); saucer.line(to: NSPoint(x: 711, y: 277))
    saucer.lineWidth = 20; saucer.lineCapStyle = .round; saucer.stroke()
    // Two broad curls, with different heights, make a distinct hand-drawn mark.
    for (x, top) in [(440.0, 777.0), (551.0, 816.0)] {
        let steam = NSBezierPath()
        steam.move(to: NSPoint(x: x, y: 647))
        steam.curve(to: NSPoint(x: x + 18, y: top), controlPoint1: NSPoint(x: x - 76, y: 703), controlPoint2: NSPoint(x: x + 85, y: top - 45))
        steam.lineWidth = 26; steam.lineCapStyle = .round; steam.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()
    let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let name: String
    switch side {
    case 16: name = "icon_16x16.png"
    case 32: name = "icon_16x16@2x.png"
    case 64: name = "icon_32x32@2x.png"
    case 128: name = "icon_128x128.png"
    case 256: name = "icon_128x128@2x.png"
    case 512: name = "icon_256x256@2x.png"
    default: name = "icon_512x512@2x.png"
    }
    try data.write(to: URL(fileURLWithPath: target).appendingPathComponent(name))
    if side == 32 { try data.write(to: URL(fileURLWithPath: target).appendingPathComponent("icon_32x32.png")) }
    if side == 256 { try data.write(to: URL(fileURLWithPath: target).appendingPathComponent("icon_256x256.png")) }
    if side == 512 { try data.write(to: URL(fileURLWithPath: target).appendingPathComponent("icon_512x512.png")) }
}
