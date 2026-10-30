import AppKit
import Foundation

@main struct MakeStatusIcons {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var variants: [String: [Int: Data]] = [:]
        for (name, color) in [("clawd-outline", NSColor.black), ("clawd-outline-light", NSColor.white)] {
            var images: [Int: Data] = [:]
            for pixels in [16, 18, 20, 24, 32, 36, 48, 64, 128, 256] {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                let flip = NSAffineTransform()
                flip.translateX(by: 0, yBy: CGFloat(pixels))
                flip.scaleX(by: 1, yBy: -1)
                flip.concat()
                ClawdStatusIcon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), color: color)
                NSGraphicsContext.restoreGraphicsState()
                let png = bitmap.representation(using: .png, properties: [:])!
                images[pixels] = png
                try png.write(to: destination.appendingPathComponent("\(name)-\(pixels).png"))
            }
            variants[name] = images
        }
        // PNG-encoded ICO entries are supported by all supported Windows versions.
        for (name, images) in variants {
            let sizes = [16, 20, 24, 32, 48, 64, 128, 256]
            var icon = Data()
            func u16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { icon.append(contentsOf: $0) } }
            func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { icon.append(contentsOf: $0) } }
            u16(0); u16(1); u16(sizes.count)
            var offset = 6 + sizes.count * 16
            for size in sizes {
                let png = images[size]!
                icon.append(contentsOf: [UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0])
                u16(1); u16(32); u32(png.count); u32(offset)
                offset += png.count
            }
            for size in sizes { icon.append(images[size]!) }
            try icon.write(to: destination.appendingPathComponent("\(name).ico"))
        }
        let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 220,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 2400, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 300, height: 220).fill()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 300, y: 0, width: 300, height: 220).fill()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: 220)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        for (x, color) in [(0.0, NSColor.black), (300.0, NSColor.white)] {
            ClawdStatusIcon.draw(in: NSRect(x: x + 18, y: 20, width: 18, height: 18), color: color)
            ClawdStatusIcon.draw(in: NSRect(x: x + 54, y: 12, width: 36, height: 36), color: color)
            ClawdStatusIcon.draw(in: NSRect(x: x + 78, y: 52, width: 144, height: 144), color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
        try preview.representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("preview.png"))
    }
}
