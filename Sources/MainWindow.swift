import AppKit
import SwiftUI

/// Owns the native window chrome independently of application/menu-bar state.
@MainActor final class QishiMainWindow: NSWindow {
    init(store: MonitorStore, claude: ClaudeStore, webRTC: WebRTCMonitor, persistFrame: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "栖时 · Claude"
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        // SwiftUI owns the toolbar and title: the split view's floating glass
        // sidebar, the page title and the glass toolbar items are all native.
        let host = NSHostingController(rootView: QishiRoot(store: store, claude: claude, webRTC: webRTC))
        host.sceneBridgingOptions = [.toolbars, .title]
        contentViewController = host
        setContentSize(NSSize(width: 1040, height: 760))
        minSize = NSSize(width: 920, height: 700)
        setAccessibilityIdentifier("qishi.mainWindow")
        if persistFrame { setFrameAutosaveName("QishiMainWindow") }
        center()
    }
}
