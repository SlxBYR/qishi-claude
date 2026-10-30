import AppKit
import SwiftUI

/// Owns the native window chrome independently of application/menu-bar state.
@MainActor final class QishiMainWindow: NSWindow {
    static let controlTopInset: CGFloat = 26

    init(store: MonitorStore, claude: ClaudeStore, persistFrame: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "栖时 · Claude"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isOpaque = false
        backgroundColor = .clear
        toolbar = NSToolbar(identifier: "QishiToolbar")
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: QishiRoot(store: store, claude: claude))
        setContentSize(NSSize(width: 1040, height: 760))
        minSize = NSSize(width: 920, height: 700)
        setAccessibilityIdentifier("qishi.mainWindow")
        if persistFrame { setFrameAutosaveName("QishiMainWindow") }
        center()
    }

    func positionWindowControls() {
        // Keep AppKit's actual controls, including their accessibility and menus.
        // Full-screen chrome is owned and positioned by the window server.
        guard !styleMask.contains(.fullScreen) else { return }
        for (index, type) in [ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(type), let parent = button.superview else { continue }
            button.setFrameOrigin(NSPoint(x: 19 + CGFloat(index) * 20,
                y: parent.bounds.height - Self.controlTopInset - button.frame.height / 2))
        }
    }
}
