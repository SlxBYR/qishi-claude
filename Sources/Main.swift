import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let reopenNotification = Notification.Name("local.qishi.claude-companion.reopen.\(getuid())")
    let store: MonitorStore
    let claude: ClaudeStore
    private(set) var pet: NSPanel?
    private(set) var nativePets: NativePets?
    private var approvalPanel: NSPanel?
    private(set) var window: NSWindow?
    private var card: NSPanel?
    private var statusItem: NSStatusItem?
    private var menuTimer: Timer?
    private var mainIsOpen = false
    private let persistWindowFrames: Bool

    init(store: MonitorStore, persistWindowFrames: Bool = true) {
        self.store = store; self.claude = ClaudeStore(preview: store.preview); self.persistWindowFrames = persistWindowFrames; super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showCompanions),
            name: Self.reopenNotification, object: nil, suspensionBehavior: .deliverImmediately)
        claude.showMain = { [weak self] in self?.showWork() }
        claude.onChange = { [weak self] in self?.updatePet(); self?.updateApprovalPanel(); self?.updateStatus() }
        claude.start()
        AppPreferences.shared.applyTheme()
        AppPreferences.shared.observeLanguage { [weak self] in
            guard let self else { return }
            self.buildMainMenu(); self.updateStatus(); self.updatePet()
            self.approvalPanel?.title = L("Claude 等你确认", "Claude needs your approval")
        }
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = ClawdStatusIcon.image
        store.onAppearanceChange = { [weak self] in
            self?.updateActivationPolicy(); self?.updateCard(); self?.updateStatus()
        }
        store.onStatusChange = { [weak self] in self?.updateStatus(); self?.updatePet() }
        updateStatus(); updatePet(); store.start()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        if store.preview && CommandLine.arguments.contains("--show-workbench") { showMain() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showCompanions(); return false }
    func application(_ application: NSApplication, open urls: [URL]) { showMain() }

    @objc func showCompanions() {
        claude.preferences.showPet = true; claude.save()
        nativePets?.claude.panel.orderFrontRegardless(); nativePets?.clawd.panel.orderFrontRegardless()
    }
    @objc func showMain() {
        if window == nil {
            let created = QishiMainWindow(store: store, claude: claude, persistFrame: persistWindowFrames)
            created.delegate = self
            window = created
        }
        mainIsOpen = true
        updateActivationPolicy()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        positionWindowControls()
        NSApp.activate(ignoringOtherApps: true)
        updateCard()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === approvalPanel {
            for request in claude.requests { claude.decide(request, choice: "native") }
            sender.orderOut(nil); return false
        }
        guard sender === window else { return true }
        mainIsOpen = false
        sender.orderOut(nil)
        card?.orderOut(nil)
        updateActivationPolicy()
        return false
    }
    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = mainIsOpen && !store.settings.hideDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if mainIsOpen { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        }
    }
    func windowDidResize(_ notification: Notification) { positionWindowControls() }
    func windowDidEndLiveResize(_ notification: Notification) { positionWindowControls() }
    private func positionWindowControls() {
        (window as? QishiMainWindow)?.positionWindowControls()
    }
    @objc func showWork() { store.selectedPage = 2; showMain() }
    @objc func togglePet() { claude.preferences.showPet.toggle(); claude.save() }
    @objc func showSettings() { store.selectedPage = 1; showMain() }
    @objc func refresh() { Task { await store.check() } }
    @objc func toggleCard() {
        if !store.settings.desktopCard && !mainIsOpen { showMain() }
        store.setDesktop(!store.settings.desktopCard)
    }
    @objc func toggleDockIcon() { store.setHideDockIcon(!store.settings.hideDockIcon) }
    @objc func toggleMonitoring() { store.setMonitoring(!store.settings.monitoring) }
    @objc func openMail() { store.openGmail() }
    @objc func quit() { NSApp.terminate(nil) }
    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key); value.target = self; return value
    }
    private func buildMainMenu() {
        let menu = NSMenu()
        let application = NSMenuItem(); let app = NSMenu()
        app.addItem(item(L("关于栖时", "About Qishi"), #selector(showMain)))
        app.addItem(.separator()); app.addItem(item(L("连接与计时…", "Connection & Timer…"), #selector(showSettings), key: ","))
        app.addItem(.separator()); app.addItem(item(L("退出栖时", "Quit Qishi"), #selector(quit), key: "q"))
        application.submenu = app; menu.addItem(application)
        let edit = NSMenuItem(title: L("编辑", "Edit"), action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: L("编辑", "Edit"))
        for (title, selector, key) in [(L("撤销", "Undo"), "undo:", "z"), (L("剪切", "Cut"), "cut:", "x"), (L("复制", "Copy"), "copy:", "c"), (L("粘贴", "Paste"), "paste:", "v"), (L("全选", "Select All"), "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        edit.submenu = editMenu; menu.addItem(edit)
        let windowMenuItem = NSMenuItem(title: L("窗口", "Window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("窗口", "Window"))
        windowMenu.addItem(NSMenuItem(title: L("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(item(L("显示栖时", "Show Qishi"), #selector(showMain)))
        windowMenuItem.submenu = windowMenu; menu.addItem(windowMenuItem)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
    }
    private func updateStatus() {
        let menu = NSMenu()
        let days = store.settings.registeredAt.map { Elapsed(since: $0, now: Date()).days }
        menu.addItem(item(days.map { L("注册至今 \($0) 天", "\($0) days since registration") } ?? L("栖时 · 等待设置", "Qishi · not set up"), nil))
        menu.addItem(item(LT(store.snapshot.status(at: Date()).title), nil))
        menu.addItem(.separator())
        menu.addItem(item("Claude · \(LT(claude.pose.title))", #selector(showWork)))
        menu.addItem(item(L("打开 Claude 工作台", "Open Claude Workbench"), #selector(showWork)))
        let petItem = item(L("显示桌面伙伴", "Show Companions"), #selector(togglePet)); petItem.state = claude.preferences.showPet ? .on : .off; menu.addItem(petItem)
        menu.addItem(item(L("打开栖时", "Open Qishi"), #selector(showMain)))
        let check = item(store.isChecking ? L("正在检查…", "Checking…") : L("立即检查 Gmail", "Check Gmail Now"), #selector(refresh))
        check.isEnabled = store.settings.isConfigured && store.settings.monitoring && !store.isChecking
        menu.addItem(check)
        let desktop = item(L("显示桌面卡片", "Show Desktop Card"), #selector(toggleCard)); desktop.state = store.settings.desktopCard ? .on : .off; menu.addItem(desktop)
        let dock = item(L("隐藏 Dock 图标", "Hide Dock Icon"), #selector(toggleDockIcon)); dock.state = store.settings.hideDockIcon ? .on : .off; menu.addItem(dock)
        if store.settings.isConfigured { menu.addItem(item(store.settings.monitoring ? L("暂停检测", "Pause Monitoring") : L("继续检测", "Resume Monitoring"), #selector(toggleMonitoring))) }
        menu.addItem(item(L("连接与计时…", "Connection & Timer…"), #selector(showSettings)))
        menu.addItem(.separator()); menu.addItem(item(L("退出栖时", "Quit Qishi"), #selector(quit), key: "q"))
        menu.autoenablesItems = false
        menu.items.filter { $0.action == nil }.forEach { $0.isEnabled = false }
        statusItem?.menu = menu
        statusItem?.button?.toolTip = L("栖时", "Qishi") + " · Claude \(LT(claude.pose.title))"
    }
    func applicationWillTerminate(_ notification: Notification) { claude.stop() }
    private func updatePet() {
        if nativePets == nil {
            nativePets = NativePets(persistent: persistWindowFrames, showMain: { [weak self] in self?.showMain() })
            pet = nativePets?.claude.panel
        }
        nativePets?.update(claude, registeredAt: store.settings.registeredAt)
    }
    private func updateApprovalPanel() {
        guard !claude.requests.isEmpty else { approvalPanel?.orderOut(nil); return }
        if approvalPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 370), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L("Claude 等你确认", "Claude needs your approval"); panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: ClaudeApprovalQueue(claude: claude))
            panel.center(); approvalPanel = panel
        }
        if approvalPanel?.isVisible != true { approvalPanel?.orderFrontRegardless() }
    }
    private func updateCard() {
        guard mainIsOpen, store.settings.desktopCard else { card?.orderOut(nil); return }
        if card == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 212), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = NSHostingView(rootView: DesktopCardView(store: store, open: { [weak self] in self?.showMain() }))
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if !(persistWindowFrames && panel.setFrameUsingName("QishiDesktopCard")), let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 392, y: screen.visibleFrame.maxY - 244))
            }
            if persistWindowFrames { panel.setFrameAutosaveName("QishiDesktopCard") }
            card = panel
        }
        card?.level = store.settings.alwaysOnTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        card?.orderFrontRegardless()
    }
}

#if !QISHI_TESTS
@main struct QishiMain {
    @MainActor static func main() {
        if ClaudeBridge.runIfNeeded() { return }
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--verify-companions"), CommandLine.arguments.count > index + 1 {
            app.setActivationPolicy(.accessory)
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    verifyCompanions(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    NSApp.terminate(nil)
                }
            }
            app.run(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        if CommandLine.arguments.contains("--demo") {
            let delegate = AppDelegate(store: MonitorStore(preview: true), persistWindowFrames: false)
            app.delegate = delegate; app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }; return
        }
        // Lock before constructing the store, status item or polling task, so
        // simultaneous launches cannot read/write settings or poll in parallel.
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QishiClaude", isDirectory: true)
        let instance = SingleInstanceLock(url: folder.appendingPathComponent("instance.lock"))
        do {
            guard try instance.acquire() else { reopenExisting(); return }
        } catch {
            let alert = NSAlert()
            alert.messageText = "栖时暂时无法启动"
            alert.informativeText = "无法建立单实例保护，请检查本机应用支持目录的权限后重试。\n\(error.localizedDescription)"
            alert.runModal(); return
        }
        // An older build may already be running without the lock protocol.
        if let existing = otherInstances().first(where: { $0.isFinishedLaunching }) {
            reopenExisting(existing); return
        }
        let delegate = AppDelegate(store: MonitorStore())
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime((delegate, instance)) { app.run() }
    }
    @MainActor static func otherInstances() -> [NSRunningApplication] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    }
    @MainActor static func reopenExisting(_ existing: NSRunningApplication? = nil) {
        if let existing = existing ?? otherInstances().first {
            existing.activate(options: [])
            if let url = existing.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        }
        // A simultaneous first launch can still be installing its observer.
        for _ in 0..<4 {
            DistributedNotificationCenter.default().postNotificationName(AppDelegate.reopenNotification,
                object: nil, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }
    @MainActor static func verifyCompanions(to folder: URL) {
        PetVerification.run(to: folder)
    }
    @MainActor static func renderPreviews(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for (page, pageName) in [(2, "claude"), (3, "companion"), (0, "dashboard"), (1, "settings")] {
                let store = MonitorStore(preview: true)
                store.selectedPage = page
                let delegate = AppDelegate(store: store, persistWindowFrames: false)
                delegate.showMain()
                guard let window = delegate.window, let host = window.contentView else { continue }
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                for (sizeName, size) in [("default", NSSize(width: 1040, height: 760)), ("compact", NSSize(width: 920, height: 700))] {
                    window.setContentSize(size)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    delegate.showMain()
                    for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                        if let button = window.standardWindowButton(type) {
                            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                            print("\(pageName)-\(name)-\(sizeName) button \(index): x=\(point.x), top inset=\(window.frame.height - point.y)")
                        }
                    }
                    let frameView = host.superview ?? host
                    if let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("qishi-\(pageName)-\(name)-\(sizeName).png"))
                    }
                }
                window.orderOut(nil)
            }
        }
    }
}
#endif
