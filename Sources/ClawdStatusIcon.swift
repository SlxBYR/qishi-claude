import AppKit

/// A template image keeps Clawd's outline legible in light, dark and selected menu bars.
/// The drawing handler is resolution-independent, so AppKit rasterizes at the screen scale.
enum ClawdStatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static var image: NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clawd · 栖时"
        return image
    }

    static func draw(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        let scale = AffineTransform(scaleByX: rect.width / size.width, byY: rect.height / size.height)
        // Continuous stepped outline follows the original Clawd torso, arms and four feet.
        let points: [NSPoint] = [
            .init(x: 2.5, y: 3.5), .init(x: 15.5, y: 3.5),
            .init(x: 15.5, y: 7.5), .init(x: 17.5, y: 7.5),
            .init(x: 17.5, y: 9.5), .init(x: 15.5, y: 9.5),
            .init(x: 15.5, y: 11.5), .init(x: 14.5, y: 11.5),
            .init(x: 14.5, y: 14.5), .init(x: 12.5, y: 14.5),
            .init(x: 12.5, y: 11.5), .init(x: 11.5, y: 11.5),
            .init(x: 11.5, y: 14.5), .init(x: 9.5, y: 14.5),
            .init(x: 9.5, y: 11.5), .init(x: 8.5, y: 11.5),
            .init(x: 8.5, y: 14.5), .init(x: 6.5, y: 14.5),
            .init(x: 6.5, y: 11.5), .init(x: 5.5, y: 11.5),
            .init(x: 5.5, y: 14.5), .init(x: 3.5, y: 14.5),
            .init(x: 3.5, y: 11.5), .init(x: 2.5, y: 11.5),
            .init(x: 2.5, y: 9.5), .init(x: 0.5, y: 9.5),
            .init(x: 0.5, y: 7.5), .init(x: 2.5, y: 7.5)
        ]
        let outline = NSBezierPath()
        outline.move(to: points[0])
        for point in points.dropFirst() { outline.line(to: point) }
        outline.close()
        outline.transform(using: scale)
        outline.transform(using: transform)
        outline.lineWidth = rect.width / size.width
        outline.lineJoinStyle = .miter
        color.setStroke()
        outline.stroke()
        color.setFill()
        for x: CGFloat in [5, 11.5] {
            let eye = NSBezierPath(rect: NSRect(x: x, y: 6.5, width: 1.5, height: 2.5))
            eye.transform(using: scale)
            eye.transform(using: transform)
            eye.fill()
        }
    }
}
