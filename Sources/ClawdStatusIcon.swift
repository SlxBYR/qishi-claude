import AppKit

/// A template image keeps Clawd's outline legible in light, dark and selected menu bars.
/// The drawing handler is resolution-independent, so AppKit rasterizes at the screen scale.
enum ClawdStatusIcon {
    static let size = NSSize(width: 18, height: 18)

    /// One outline pose: lifted legs (0–3, left to right) and each arm's vertical offset.
    struct Pose: Equatable {
        var lifted: Set<Int> = []
        var arms: (left: CGFloat, right: CGFloat) = (0, 0)
        static let rest = Pose()
        static func == (a: Pose, b: Pose) -> Bool { a.lifted == b.lifted && a.arms == b.arms }
    }
    /// Walk in place: diagonal leg pairs step while the arms swing against them.
    /// Every other frame is the resting logo, so starting or stopping never jumps.
    static let walk: [Pose] = [
        Pose(lifted: [0, 2], arms: (-1, 1)), .rest,
        Pose(lifted: [1, 3], arms: (1, -1)), .rest
    ]
    static let walkFrameDuration: CFTimeInterval = 0.16

    static var image: NSImage { image(pose: .rest) }

    static func image(pose: Pose) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(in: rect, color: .black, pose: pose)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clawd · 栖时"
        return image
    }

    static func draw(in rect: NSRect, color: NSColor, pose: Pose = .rest) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        let scale = AffineTransform(scaleByX: rect.width / size.width, byY: rect.height / size.height)
        // Continuous stepped outline follows the original Clawd torso, arms and four feet.
        let left = 7.5 + pose.arms.left, right = 7.5 + pose.arms.right
        var points: [NSPoint] = [
            .init(x: 2.5, y: 3.5), .init(x: 15.5, y: 3.5),
            .init(x: 15.5, y: right), .init(x: 17.5, y: right),
            .init(x: 17.5, y: right + 2), .init(x: 15.5, y: right + 2),
            .init(x: 15.5, y: 11.5)
        ]
        for leg in (0..<4).reversed() {
            let x = 3.5 + CGFloat(leg) * 3, foot = pose.lifted.contains(leg) ? 13.5 : 14.5
            points += [.init(x: x + 2, y: 11.5), .init(x: x + 2, y: foot), .init(x: x, y: foot), .init(x: x, y: 11.5)]
        }
        points += [
            .init(x: 2.5, y: 11.5), .init(x: 2.5, y: left + 2),
            .init(x: 0.5, y: left + 2), .init(x: 0.5, y: left),
            .init(x: 2.5, y: left)
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

/// Menu bar Clawd in the RunCatNeo manner: the button keeps a blank template image for its width,
/// and a tinted layer masked by pre-rendered poses shows Clawd. Walking is a discrete Core Animation
/// keyframe loop, so no timer redraws the status item while Claude works.
@MainActor final class ClawdStatusAnimator {
    private let tint = CALayer()
    private let mask = CALayer()
    private weak var button: NSStatusBarButton?
    private var appearance: NSKeyValueObservation?
    private var frame: NSKeyValueObservation?
    private(set) var walking = false

    init(button: NSStatusBarButton) {
        self.button = button
        let blank = NSImage(size: ClawdStatusIcon.size)
        blank.isTemplate = true
        button.image = blank
        button.setAccessibilityLabel("Clawd · 栖时")
        button.wantsLayer = true
        mask.contentsGravity = .resizeAspect
        mask.contents = Self.contents(.rest)
        tint.mask = mask
        button.layer?.addSublayer(tint)
        appearance = button.observe(\.effectiveAppearance, options: [.initial]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyTint() }
        }
        frame = button.observe(\.frame, options: [.initial]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func setWalking(_ walk: Bool) {
        guard walk != walking else { return }
        walking = walk
        mask.removeAnimation(forKey: "walk")
        guard walk else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = ClawdStatusIcon.walk.map(Self.contents)
        animation.calculationMode = .discrete
        animation.duration = ClawdStatusIcon.walkFrameDuration * Double(ClawdStatusIcon.walk.count)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        mask.add(animation, forKey: "walk")
    }

    private func layout() {
        guard let button else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let size = ClawdStatusIcon.size, bounds = button.bounds
        tint.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height).integral
        mask.frame = tint.bounds
        CATransaction.commit()
    }
    private func applyTint() {
        guard let button else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        button.effectiveAppearance.performAsCurrentDrawingAppearance { tint.backgroundColor = NSColor.textColor.cgColor }
        CATransaction.commit()
    }
    /// Rendered at 3x so the 1 pt outline stays crisp on every display.
    private static func contents(_ pose: ClawdStatusIcon.Pose) -> CGImage? {
        let scale = 3, width = Int(ClawdStatusIcon.size.width) * scale, height = Int(ClawdStatusIcon.size.height) * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        ClawdStatusIcon.draw(in: NSRect(x: 0, y: 0, width: width, height: height), color: .black, pose: pose)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}
