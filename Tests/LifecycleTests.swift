import AppKit
import SwiftUI

@main struct LifecycleTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lock" {
            let lock = SingleInstanceLock(url: URL(fileURLWithPath: CommandLine.arguments[2]))
            if try lock.acquire() {
                print("ACQUIRED"); fflush(stdout)
                withExtendedLifetime(lock) { Thread.sleep(forTimeInterval: 2) }
            } else { print("BLOCKED") }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = MonitorStore(preview: true)
        let delegate = AppDelegate(store: store, persistWindowFrames: false)
        app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard delegate.window == nil else { fatalError("Unexpected launch dashboard") }
        delegate.showMain()
        guard let window = delegate.window else { fatalError("No requested main window") }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        settle()
        expect(window.isVisible, "workbench opens only on request")
        expect(app.activationPolicy() == .regular, "default open window has Dock presence")
        // AppKit places the window controls; the app no longer repositions them.
        let controls = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        expect(controls.count == 3 && controls.allSatisfy { !$0.isHidden && $0.window === window }, "system window controls are present")
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(window.contentView!.superview ?? window.contentView!)
        expect(views.contains { $0 is NSSplitView }, "navigation uses the native split view")
        expect(window.toolbar != nil && !(window.toolbar?.items.isEmpty ?? true), "SwiftUI toolbar items are bridged into the window toolbar")
        let titles = [2: L("Claude 工作台", "Claude Workbench"), 3: L("桌宠与接入", "Companions & Integration"),
                      0: L("账户守护", "Account"), 1: L("连接与计时", "Connection & Timer")]
        for (sizeName, size) in [("default", NSSize(width: 1040, height: 760)),
                                 ("compact", NSSize(width: 920, height: 700))] {
            window.setContentSize(size); settle()
            for page in [2, 3, 0, 1] {
                store.selectedPage = page; settle()
                expect(window.title == titles[page], "\(sizeName) page \(page) title is bridged to the native window title")
                // The native sidebar is an NSOutlineView; its rows are read from
                // AppKit directly (the section header row precedes the pages).
                store.selectedPage = page == 2 ? 1 : 2; settle()
                guard let outline = descendants(window.contentView!.superview ?? window.contentView!).compactMap({ $0 as? NSOutlineView }).first,
                      let index = [2, 3, 0, 1].firstIndex(of: page) else { fatalError("Missing native sidebar") }
                let rowIndex = outline.numberOfRows - 4 + index
                let row = window.convertToScreen(outline.convert(outline.rect(ofRow: rowIndex), to: nil))
                expect(row.width >= 150 && row.height >= 24, "\(sizeName) sidebar \(page) exposes the full row bounds")
                // Nothing may cover the row: AppKit hit-testing near each edge of
                // the selection capsule must land inside the sidebar outline.
                for (edge, point) in [("left", NSPoint(x: row.minX + 14, y: row.midY)), ("right", NSPoint(x: row.maxX - 14, y: row.midY)),
                                      ("top", NSPoint(x: row.midX, y: row.maxY - 4)), ("bottom", NSPoint(x: row.midX, y: row.minY + 4))] {
                    let hit = window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: point))
                    expect(hit.map { $0 === outline || $0.isDescendant(of: outline) } == true,
                           "\(sizeName) sidebar \(page) \(edge) edge of the row is not covered")
                }
                // A terminal-launched harness cannot become the active app, so
                // AppKit drives the native selection and the binding must follow.
                outline.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false); settle()
                expect(store.selectedPage == page, "\(sizeName) sidebar \(page) native selection drives the page")
            }
        }
        window.setContentSize(NSSize(width: 1040, height: 760)); settle()
        for _ in 0..<8 { delegate.showMain() }
        expect(delegate.window === window && app.windows.filter { $0.accessibilityIdentifier() == "qishi.mainWindow" }.count == 1, "repeated opens reuse one window")
        store.setHideDockIcon(true); settle()
        expect(app.activationPolicy() == .accessory && window.isVisible, "hide Dock immediately preserves open window")
        store.setHideDockIcon(false); settle()
        expect(app.activationPolicy() == .regular && window.isVisible, "show Dock immediately preserves open window")
        delegate.claude.preferences.showClaude = false; delegate.claude.save(); settle()
        let pets = delegate.nativePets!
        expect(!pets.claude.panel.isVisible && pets.clawd.panel.isVisible, "Claude-chan hides on her own while Clawd stays")
        delegate.claude.preferences.showClaude = true; delegate.claude.preferences.showClawd = false; delegate.claude.save(); settle()
        expect(pets.claude.panel.isVisible && !pets.clawd.panel.isVisible, "Clawd hides on his own while Claude-chan stays")
        delegate.claude.preferences.showClaude = false; delegate.claude.save(); settle()
        window.performClose(nil); settle()
        expect(!window.isVisible && app.activationPolicy() == .accessory, "close leaves menu-bar-only app")
        expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "background process stays alive after close")
        store.setHideDockIcon(false); settle()
        expect(app.activationPolicy() == .accessory && !window.isVisible, "changing Dock preference while closed does not reopen")
        delegate.showMain(); settle()
        expect(delegate.window === window && window.isVisible && app.activationPolicy() == .regular, "reopen restores original window and Dock preference")
        window.miniaturize(nil); settle()
        delegate.showMain(); settle()
        expect(!window.isMiniaturized && window.isVisible, "reopen restores minimized window")
        store.setHideDockIcon(true)
        window.performClose(nil); delegate.showMain(); settle()
        expect(app.activationPolicy() == .accessory && window.isVisible, "hidden Dock preference survives close and reopen")
        window.orderOut(nil)
        print("PASS: lifecycle integration complete; preview store performs no persistence or mail access")
    }
}
