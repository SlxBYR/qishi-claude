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
        // SwiftUI builds its accessibility tree lazily. Enable enhanced UI only
        // on this test application, as an accessibility client would request it.
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            print("PASS: \(message)")
        }
        settle()
        expect(window.isVisible, "workbench opens only on request")
        expect(app.activationPolicy() == .regular, "default open window has Dock presence")
        let centers = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind -> NSPoint in
            let button = window.standardWindowButton(kind)!
            return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }
        expect(centers.map(\.x) == [26, 46, 66], "traffic-light horizontal positions unchanged")
        expect(centers.allSatisfy { abs(window.frame.height - $0.y - 26) < 0.1 }, "traffic-light top inset remains 26 pt")
        // Read the rendered SwiftUI accessibility frames, then send ordinary
        // mouse events through AppKit. Performing an accessibility "press" here
        // would bypass hit-testing and would not catch the original padding bug.
        func renderedFrame(_ identifier: String) -> NSRect? {
            func find(_ value: Any) -> NSRect? {
                if let element = value as? NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == identifier {
                    return element.accessibilityFrame()
                }
                if let element = value as? NSAccessibilityProtocol {
                    if element.accessibilityIdentifier() == identifier { return element.accessibilityFrame() }
                    for child in element.accessibilityChildren() ?? [] {
                        if let frame = find(child) { return frame }
                    }
                }
                return nil
            }
            return find(window)
        }
        func click(screenPoint: NSPoint) {
            let point = window.convertPoint(fromScreen: screenPoint)
            let timestamp = ProcessInfo.processInfo.systemUptime
            for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                let event = NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: timestamp + Double(number) * 0.01,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: number + 1, clickCount: 1, pressure: number == 0 ? 1 : 0)!
                app.postEvent(event, atStart: false)
            }
            // NSApp.run is not entered by this harness; service its mouse queue
            // explicitly, retaining the real window/responder event dispatch.
            while let event = app.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            settle()
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let nativeGlass = descendants(window.contentView!).compactMap { $0 as? NSGlassEffectView }
        expect(nativeGlass.contains { $0.bounds.width >= 180 && $0.bounds.height >= 600 && $0.style == .regular },
               "sidebar uses a rendered native Liquid Glass view")
        for (sizeName, size) in [("default", NSSize(width: 1040, height: 760)),
                                 ("compact", NSSize(width: 920, height: 700))] {
            window.setContentSize(size); settle()
            for page in [2, 3, 0, 1] {
                store.selectedPage = page; settle()
                guard let title = renderedFrame("page-title") else { fatalError("Missing rendered page title") }
                let titleTop = window.frame.maxY - title.maxY
                expect((20...36).contains(titleTop) && title.minX > window.frame.minX + 188,
                       "\(sizeName) page \(page) title has a compact top inset without covering window controls")
                for edge in ["left", "right", "top", "bottom"] {
                    store.selectedPage = page == 2 ? 1 : 2; settle()
                    guard let row = renderedFrame("sidebar-\(page)") else { fatalError("Missing rendered sidebar button") }
                    expect(row.width >= 150 && row.height >= 36, "\(sizeName) sidebar \(page) exposes the full row bounds")
                    let point: NSPoint
                    switch edge {
                    case "left": point = NSPoint(x: row.minX + 2, y: row.midY)
                    case "right": point = NSPoint(x: row.maxX - 2, y: row.midY)
                    case "top": point = NSPoint(x: row.midX, y: row.maxY - 2)
                    default: point = NSPoint(x: row.midX, y: row.minY + 2)
                    }
                    click(screenPoint: point)
                    expect(store.selectedPage == page,
                           "\(sizeName) sidebar \(page) \(edge) padding receives mouse clicks")
                }
            }
        }
        window.setContentSize(NSSize(width: 1040, height: 760)); settle()
        for _ in 0..<8 { delegate.showMain() }
        expect(delegate.window === window && app.windows.filter { $0.title == "栖时 · Claude" }.count == 1, "repeated opens reuse one window")
        store.setHideDockIcon(true); settle()
        expect(app.activationPolicy() == .accessory && window.isVisible, "hide Dock immediately preserves open window")
        store.setHideDockIcon(false); settle()
        expect(app.activationPolicy() == .regular && window.isVisible, "show Dock immediately preserves open window")
        delegate.claude.preferences.showPet = false; delegate.claude.save(); settle()
        store.setDesktop(true); settle()
        expect(app.windows.contains { $0 is NSPanel && $0.isVisible }, "desktop card opens")
        window.performClose(nil); settle()
        expect(!window.isVisible && app.activationPolicy() == .accessory, "close leaves menu-bar-only app")
        expect(!app.windows.contains { $0 is NSPanel && $0.isVisible }, "close also hides desktop card")
        expect(store.settings.desktopCard, "closing retains desktop-card preference")
        expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "background process stays alive after close")
        store.setHideDockIcon(false); settle()
        expect(app.activationPolicy() == .accessory && !window.isVisible, "changing Dock preference while closed does not reopen")
        delegate.showMain(); settle()
        expect(delegate.window === window && window.isVisible && app.activationPolicy() == .regular, "reopen restores original window and Dock preference")
        expect(app.windows.contains { $0 is NSPanel && $0.isVisible }, "reopen restores desktop-card preference")
        store.setDesktop(false)
        window.miniaturize(nil); settle()
        delegate.showMain(); settle()
        expect(!window.isMiniaturized && window.isVisible, "reopen restores minimized window")
        store.setHideDockIcon(true)
        window.performClose(nil); delegate.showMain(); settle()
        expect(app.activationPolicy() == .accessory && window.isVisible, "hidden Dock preference survives close and reopen")
        window.setContentSize(NSSize(width: 1000, height: 760)); settle()
        let close = window.standardWindowButton(.closeButton)!
        let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        expect(point.x == 26 && abs(window.frame.height - point.y - 26) < 0.1, "resize keeps traffic lights anchored")
        // Keep the exact QishiMainWindow chrome and PageHeader layout, but
        // replace the external "open Claude" effect with a local counter.
        // This catches an empty NSToolbar intercepting content near the top.
        var headerClicks = 0
        window.contentViewController = NSHostingController(rootView: HeaderHitProbe { headerClicks += 1 })
        for (sizeName, size) in [("default", NSSize(width: 1040, height: 760)),
                                 ("compact", NSSize(width: 920, height: 700))] {
            window.setContentSize(size); window.makeKeyAndOrderFront(nil); settle()
            guard let action = renderedFrame("header-action-probe") else { fatalError("Missing rendered header action") }
            expect(abs(window.frame.maxY - action.midY - 40) < 1,
                   "\(sizeName) native header action remains at the titlebar height")
            for (edge, point) in [
                ("center", NSPoint(x: action.midX, y: action.midY)),
                ("left", NSPoint(x: action.minX + 3, y: action.midY)),
                ("right", NSPoint(x: action.maxX - 3, y: action.midY)),
                ("top", NSPoint(x: action.midX, y: action.maxY - 3)),
                ("bottom", NSPoint(x: action.midX, y: action.minY + 3))
            ] {
                let before = headerClicks
                click(screenPoint: point)
                expect(headerClicks == before + 1,
                       "\(sizeName) header action \(edge) click passes native titlebar chrome")
            }
        }
        window.orderOut(nil)
        print("PASS: lifecycle integration complete; preview store performs no persistence or mail access")
    }
}

// The production header and root geometry, with no network or application launch.
private struct HeaderHitProbe: View {
    var action: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: QishiLayout.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                PageHeader(title: "Claude 工作台") {
                    Button(action: action) { Label("打开 Claude", systemImage: "arrow.up.forward.app") }
                        .accessibilityIdentifier("header-action-probe")
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 800, minHeight: 630)
            .ignoresSafeArea(.container, edges: .top)
            .tint(.qishiAccent)
    }
}
