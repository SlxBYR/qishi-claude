import AppKit

let destination = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: destination)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let size = points * scale
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let rect = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.87, alpha: 1).setFill(); shape.fill()
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.99, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.92, green: 0.87, blue: 0.78, alpha: 1))?.draw(in: shape, angle: -90)
    let hourglass = NSBezierPath()
    hourglass.move(to: NSPoint(x: s * 0.34, y: s * 0.73))
    hourglass.line(to: NSPoint(x: s * 0.66, y: s * 0.73))
    hourglass.curve(to: NSPoint(x: s * 0.54, y: s * 0.5), controlPoint1: NSPoint(x:s*0.66,y:s*0.61),controlPoint2:NSPoint(x:s*0.58,y:s*0.55))
    hourglass.curve(to: NSPoint(x: s * 0.66, y: s * 0.27), controlPoint1: NSPoint(x:s*0.58,y:s*0.45),controlPoint2:NSPoint(x:s*0.66,y:s*0.39))
    hourglass.line(to: NSPoint(x: s * 0.34, y: s * 0.27))
    hourglass.curve(to: NSPoint(x: s * 0.46, y: s * 0.5), controlPoint1: NSPoint(x:s*0.34,y:s*0.39),controlPoint2:NSPoint(x:s*0.42,y:s*0.45))
    hourglass.curve(to: NSPoint(x: s * 0.34, y: s * 0.73), controlPoint1: NSPoint(x:s*0.42,y:s*0.55),controlPoint2:NSPoint(x:s*0.34,y:s*0.61))
    hourglass.close()
    NSColor(calibratedRed: 0.73, green: 0.35, blue: 0.19, alpha: 1).setFill(); hourglass.fill()
    let shine = NSBezierPath(roundedRect: NSRect(x:s*0.39,y:s*0.655,width:s*0.22,height:s*0.025), xRadius:s*0.012,yRadius:s*0.012)
    NSColor.white.withAlphaComponent(0.6).setFill(); shine.fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
}
