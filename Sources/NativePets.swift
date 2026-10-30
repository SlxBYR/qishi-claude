import AppKit
import WebKit

// A single local origin lets the original renderer reach the SVG's eye/body nodes.
// No HTTP server, internet access, or files outside this bundle are involved.
final class PetResourceHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root = Bundle.main.resourceURL else { return }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf:file) else {
            urlSchemeTask.didFailWithError(NSError(domain:NSURLErrorDomain,code:NSURLErrorFileDoesNotExist)); return
        }
        let mime = ["html":"text/html","js":"application/javascript","css":"text/css","svg":"image/svg+xml","webp":"image/webp","png":"image/png","json":"application/json"][file.pathExtension] ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:mime.hasPrefix("text/") || file.pathExtension == "js" ? "utf-8" : nil))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor final class PetDragView: NSView {
    weak var owner: NativePetWindow?
    private var down = NSPoint.zero, origin = NSPoint.zero
    private var dragged = false, swingX: CGFloat = 0, direction: CGFloat = 0
    private var swings: [Date] = [], lastShake = Date.distantPast
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { owner?.showAccount(); return true }
    override func mouseDown(with event: NSEvent) { down = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragged {
            guard abs(p.x-down.x)+abs(p.y-down.y)>3 else { return }
            dragged = true; owner?.beginDrag(); origin = window?.frame.origin ?? .zero; down = p
            swingX = p.x; direction = 0; swings = []
        }
        if direction == 0 {
            if abs(p.x-swingX)>18 { direction = p.x>swingX ? 1 : -1; swingX = p.x }
        } else if (p.x-swingX)*direction>0 { swingX = p.x }
        else if (swingX-p.x)*direction>18 {
            direction = -direction; swingX = p.x; swings.append(Date())
            swings = swings.filter { Date().timeIntervalSince($0)<0.9 }
            if swings.count>=2 && Date().timeIntervalSince(lastShake)>0.3 { lastShake = Date(); owner?.shake() }
        }
        window?.setFrameOrigin(NSPoint(x:origin.x+p.x-down.x,y:origin.y+p.y-down.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { owner?.endDrag() }
        else { owner?.click(convert(event.locationInWindow, from:nil), count:event.clickCount) }
        dragged = false
    }
    override func rightMouseDown(with event: NSEvent) { owner?.showMenu(event, in:self) }
}

@MainActor final class NativePetWindow: NSObject, WKNavigationDelegate {
    enum Kind: String { case claude, clawd }
    let kind: Kind
    let panel: NSPanel
    let web: WKWebView
    let persistent: Bool
    var ready = false, dragging = false
    var showMain: (() -> Void)?
    var hide: (() -> Void)?
    private var pendingScript: String?
    private var timer: Timer?
    private var lastMouse = NSPoint.zero, tickInFlight = false
    private var dock: String?, tucked = false, dockOut = false, peek = false
    private var dockedAt = Date.distantPast, lastWork = Date.distantPast
    private var hoverSince: Date?, leaveSince: Date?
    private var slideTimer: Timer?, slideTarget: NSPoint?
    private var slideVelocity = NSPoint.zero, slideTimestamp: TimeInterval = 0
    private var dockGeneration = 0
    private var scale: CGFloat = 1
    private var baseSize: NSSize { kind == .claude ? NSSize(width:260,height:300) : NSSize(width:180,height:180) }
    private var frameKey: String { "QishiOriginalPet-\(kind.rawValue)" }

    init(kind: Kind, persistent: Bool) {
        self.kind = kind; self.persistent = persistent
        let size = kind == .claude ? NSSize(width:260,height:300) : NSSize(width:180,height:180)
        panel = NSPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(PetResourceHandler(),forURLScheme:"qishi-pet")
        config.websiteDataStore = persistent ? .default() : .nonPersistent()
        web = WKWebView(frame:NSRect(origin:.zero,size:size),configuration:config)
        super.init()
        panel.title = kind == .claude ? "Claude" : "Clawd"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let container = NSView(frame:NSRect(origin:.zero,size:size))
        web.setValue(false,forKey:"drawsBackground"); web.autoresizingMask = [.width,.height]
        web.navigationDelegate = self; container.addSubview(web)
        let drag = PetDragView(frame:container.bounds); drag.owner = self; drag.autoresizingMask = [.width,.height]
        drag.setAccessibilityElement(true); drag.setAccessibilityRole(.button)
        drag.setAccessibilityLabel(kind == .claude ? L("Claude 娘，点击查看账号存活天数，拖动改变位置", "Claude-chan: click to show account age, drag to move") : L("Clawd，点击互动，拖动改变位置", "Clawd: click to interact, drag to move"))
        container.addSubview(drag); panel.contentView = container
        if !(persistent && panel.setFrameUsingName(frameKey)), let screen = NSScreen.main {
            let right: CGFloat = kind == .claude ? 210 : 30
            panel.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-size.width-right,y:screen.visibleFrame.minY+30))
        }
        let page = kind == .claude ? "CrossPet" : "ClawdWeb"
        web.load(URLRequest(url:URL(string:"qishi-pet://bundle/\(page)/index.html")!))
        timer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    deinit { timer?.invalidate(); slideTimer?.invalidate() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("window.qishiReady === true") { [weak self] result, error in
            guard let self, result as? Bool == true, error == nil else { return }
            self.ready = true
            if let script = self.pendingScript { self.run(script); self.pendingScript = nil }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "qishi-pet" || navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func run(_ script: String) {
        guard ready else { if script != "void 0" { pendingScript = script }; return }
        web.evaluateJavaScript(script) { _, error in if let error { NSLog("Pet %@: %@",self.kind.rawValue,error.localizedDescription) } }
    }
    func present(show: Bool, scale newScale: Double, onTop: Bool) {
        let nextScale = CGFloat(min(1.5,max(0.6,newScale)))
        if nextScale != scale {
            cancelSlide()
            scale = nextScale; web.pageZoom = scale
            panel.setContentSize(NSSize(width:baseSize.width*scale,height:baseSize.height*scale))
        }
        panel.level = onTop ? .floating : .normal
        if show {
            if !panel.isVisible { panel.orderFrontRegardless(); if ready { run("qishiHidden(false)") } }
        } else { cancelSlide(); if ready { run("qishiHidden(true)") }; panel.orderOut(nil) }
    }
    func receive(_ script: String, activity: Date?) {
        run(script)
        if let activity, activity>dockedAt { lastWork = activity }
        if dock != nil {
            let busy = Date().timeIntervalSince(lastWork)<10
            if dockOut != busy { dockOut = busy; applyDock() }
        }
    }
    private func tick() {
        guard ready, panel.isVisible, !tickInFlight else { return }
        let p = NSEvent.mouseLocation
        let local = NSPoint(x:(p.x-panel.frame.minX)/scale,y:(panel.frame.maxY-p.y)/scale)
        let moved = p != lastMouse; lastMouse = p
        let pointer = kind == .clawd ? "qishiPointer(\(local.x),\(local.y),\(moved),\(p.x > (panel.screen?.frame.midX ?? 0)));" : ""
        let script = "\(pointer)qishiHitTest(\(local.x),\(local.y))"
        tickInFlight = true
        web.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            self.tickInFlight = false
            let inside = value as? Bool == true
            self.panel.ignoresMouseEvents = !inside && !self.dragging
            self.updateHover(inside)
        }
        if dock != nil, dockOut, Date().timeIntervalSince(lastWork)>=10 { dockOut = false; applyDock() }
    }
    func click(_ p: NSPoint, count: Int) {
        let x = p.x/scale, y = (panel.frame.height-p.y)/scale
        if kind == .claude { revealAccountPosition() }
        run(kind == .claude ? "qishiClick(\(x),\(y))" : "qishiClick(\(x),\(count))")
    }
    @objc func showAccount() {
        guard kind == .claude else { pat(); return }
        revealAccountPosition()
        run("qishiClick()")
    }
    private func revealAccountPosition() {
        cancelSlide()
        if dock != nil {
            dock = nil; tucked = false; dockOut = false; peek = false
            hoverSince = nil; leaveSince = nil
            run("setTucked(null)")
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame, vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x:min(max(f.minX,vf.minX),vf.maxX-f.width),
                                     y:min(max(f.minY,vf.minY),vf.maxY-f.height)))
    }
    func shake() { run(kind == .claude ? "shaken()" : "qishiShake()") }
    func beginDrag() {
        cancelSlide()
        hoverSince = nil; leaveSince = nil
        dragging = true; dock = nil; tucked = false; dockOut = false; peek = false
        run(kind == .claude ? "qishiDrag(true)" : "qishiTuck(null);qishiDrag(true)")
    }
    func endDrag() {
        dragging = false
        run("qishiDrag(false)")
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame, vf = screen.visibleFrame, reach = f.width*0.3
        func neighbor(_ left: Bool) -> Bool {
            NSScreen.screens.contains { $0 !== screen && $0.frame.minY<f.maxY && $0.frame.maxY>f.minY &&
                (left ? abs($0.frame.maxX-screen.frame.minX)<2 : abs($0.frame.minX-screen.frame.maxX)<2) }
        }
        if f.midX-vf.minX<reach && !neighbor(true) { dock = "left" }
        else if vf.maxX-f.midX<reach && !neighbor(false) { dock = "right" }
        if dock != nil { dockedAt = Date(); dockOut = false; applyDock() }
        else {
            panel.setFrameOrigin(NSPoint(x:min(max(f.minX,vf.minX),vf.maxX-f.width),y:min(max(f.minY,vf.minY),vf.maxY-f.height)))
        }
        if persistent { panel.saveFrame(usingName:frameKey) }
    }
    private func updateHover(_ inside: Bool) {
        // Only Clawd peeks out under the pointer; Claude-chan's tuck is static.
        guard kind == .clawd, dock != nil, !dockOut, !dragging else { return }
        if inside {
            leaveSince = nil
            if !peek {
                if hoverSince == nil { hoverSince = Date() }
                else if Date().timeIntervalSince(hoverSince!)>0.15 { peek = true; hoverSince = nil; applyDock() }
            }
        } else {
            hoverSince = nil
            if peek {
                if leaveSince == nil { leaveSince = Date() }
                else if Date().timeIntervalSince(leaveSince!)>0.3 { peek = false; leaveSince = nil; applyDock() }
            }
        }
    }
    private func applyDock() {
        guard let side = dock, let screen = panel.screen ?? NSScreen.main else { return }
        dockGeneration += 1
        let generation = dockGeneration
        let vf = screen.visibleFrame
        var frame = panel.frame
        frame.origin.y = min(max(frame.minY,vf.minY),vf.maxY-frame.height)
        frame.origin.x = side == "left" ? vf.minX : vf.maxX-frame.width
        let hidden = !dockOut
        run(kind == .claude ? "setTucked(\(hidden ? Self.json(side) : "null"),\(peek))" : "qishiTuck(\(hidden ? Self.json(side) : "null"),\(peek))")
        if kind == .clawd && hidden {
            frame.origin.x += (side == "left" ? -1 : 1)*frame.width*(peek ? 0.36 : 0.486)
        }
        slide(frame)
        if kind == .claude && hidden {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.45) { [weak self] in
                guard let self, self.dockGeneration == generation, self.dock == side, !self.dockOut, !self.dragging else { return }
                self.web.evaluateJavaScript("dockCut(\(Self.json(side)))") { value, _ in
                    guard let cut = value as? Double, self.dockGeneration == generation, self.dock == side, !self.dockOut, !self.dragging else { return }
                    var f = self.panel.frame; f.origin.x = (side == "left" ? vf.minX : vf.maxX)-cut*self.scale
                    self.slide(f)
                }
            }
        }
        tucked = hidden
    }
    private func cancelSlide() {
        dockGeneration += 1
        slideTimer?.invalidate(); slideTimer = nil; slideTarget = nil
        slideVelocity = .zero
    }
    private func slide(_ frame: NSRect) {
        if kind == .claude {
            // One cancellable owner advances from the actual preceding position.
            // Retargeting keeps velocity; dragging cancels before taking the origin.
            guard slideTarget != frame.origin else { return }
            slideTarget = frame.origin
            if slideTimer != nil { return }
            if hypot(panel.frame.minX-frame.minX,panel.frame.minY-frame.minY)<0.1 {
                slideTarget = nil; return
            }
            slideTimestamp = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in
                Task { @MainActor in self?.advanceSlide() }
            }
            slideTimer = timer
            RunLoop.main.add(timer,forMode:.common)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35; context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            panel.animator().setFrame(frame,display:true)
        }
    }
    private func advanceSlide() {
        guard let target = slideTarget, !dragging else { cancelSlide(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05,max(0,now-slideTimestamp)); slideTimestamp = now
        // Analytic critical damping is stable across refresh rates and has no bounce.
        let omega: CGFloat = 22, elapsed = CGFloat(dt), decay = exp(-omega*elapsed)
        func advance(_ position: CGFloat, _ velocity: CGFloat, _ destination: CGFloat) -> (CGFloat,CGFloat) {
            let offset = position-destination, c = velocity+omega*offset
            return (destination+(offset+c*elapsed)*decay,(velocity-omega*c*elapsed)*decay)
        }
        let x = advance(panel.frame.minX,slideVelocity.x,target.x)
        let y = advance(panel.frame.minY,slideVelocity.y,target.y)
        slideVelocity = NSPoint(x:x.1,y:y.1)
        if hypot(x.0-target.x,y.0-target.y)<0.1 && hypot(x.1,y.1)<1 {
            panel.setFrameOrigin(target)
            slideTimer?.invalidate(); slideTimer = nil; slideTarget = nil; slideVelocity = .zero
        } else { panel.setFrameOrigin(NSPoint(x:x.0,y:y.0)) }
    }
    func showMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        if kind == .claude {
            let item = NSMenuItem(title:L("账号存活天数", "Account Age"),action:#selector(showAccount),keyEquivalent:"")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }
        for (title, action) in [(kind == .claude ? L("摸摸头", "Pat") : L("逗逗 Clawd", "Play with Clawd"),#selector(pat)),(L("戳一下", "Poke"),#selector(poke)),(kind == .claude ? L("隐藏 Claude 娘", "Hide Claude-chan") : L("隐藏 Clawd", "Hide Clawd"),#selector(hidePet)),(L("打开栖时", "Open Qishi"),#selector(openMain)),(L("退出", "Quit"),#selector(quit))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:view)
    }
    @objc private func pat() { run(kind == .claude ? "handleClick('pat')" : "qishiClick(30)") }
    @objc private func poke() { run(kind == .claude ? "handleClick('poke')" : "qishiClick(130,2)") }
    @objc private func openMain() { showMain?() }
    @objc private func hidePet() { hide?() }
    @objc private func quit() {
        run(kind == .claude ? "farewell('',2000)" : "qishiClick(90,2)")
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { NSApp.terminate(nil) }
    }
    static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys])
        return String(data:data,encoding:.utf8)!
    }
}

@MainActor final class NativePets {
    let claude: NativePetWindow, clawd: NativePetWindow
    private var lastPayload = "", lastState = ""
    init(persistent: Bool, showMain: @escaping () -> Void, hide: @escaping (NativePetWindow.Kind) -> Void) {
        claude = NativePetWindow(kind:.claude,persistent:persistent)
        clawd = NativePetWindow(kind:.clawd,persistent:persistent)
        claude.showMain = showMain; clawd.showMain = showMain
        claude.hide = { hide(.claude) }; clawd.hide = { hide(.clawd) }
    }
    func update(_ store: ClaudeStore, registeredAt: Date? = nil) {
        for (pet, show) in [(claude, store.preferences.showClaude), (clawd, store.preferences.showClawd)] { pet.present(show:show,scale:store.preferences.petScale,onTop:store.preferences.alwaysOnTop) }
        let live = store.live
        func state(_ s: ClaudeSession) -> [String:Any] {
            var p = s.pose == .error ? "oops" : s.pose.rawValue
            if s.pose == .happy && s.toolCount>=8 { p = "proud" }
            return ["pose":p,"event":s.event,"ts":s.updated,"tool":s.tool]
        }
        var payload: [String:Any] = ["sessions":Dictionary(uniqueKeysWithValues:live.map { ($0.id,state($0)) })]
        payload["registeredAt"] = registeredAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        payload["lang"] = Loc.language.rawValue
        if let current = live.first(where:{$0.pose.busy || $0.pose == .asking}) ?? live.first { payload["state"] = state(current) }
        if !store.requests.isEmpty { payload["state"] = ["pose":"asking","event":"PermissionRequest","ts":store.now.timeIntervalSince1970] }
        if let s = store.focus, let ts = s.quotaUpdated, store.now.timeIntervalSince1970-ts<900 {
            payload["quota"] = ["low":s.quota.contains{$0.used>=90}]
        }
        let json = NativePetWindow.json(payload)
        let activity = live.contains{$0.pose.busy || $0.pose == .asking} ? Date() : live.first.map{Date(timeIntervalSince1970:$0.updated)}
        if json != lastPayload { lastPayload = json; claude.receive("qishiUpdate(\(json))",activity:activity) }
        else if let activity { claude.receive("void 0",activity:activity) }
        let p = store.pose
        var s = "idle", file = "clawd-idle-follow.svg"
        switch p {
        case .thinking: s = "thinking"; file = "clawd-working-thinking.svg"
        case .reading, .searching: s = "working"; file = "clawd-idle-reading.svg"
        case .writing, .running: s = "working"; file = "clawd-working-typing.svg"
        case .delegating: s = "juggling"; file = "clawd-headphones-groove.svg"
        case .asking: s = "notification"; file = "clawd-notification.svg"
        case .compact: s = "sweeping"; file = "clawd-working-sweeping.svg"
        case .happy: s = "attention"; file = "clawd-happy.svg"
        case .error: s = "error"; file = "clawd-error.svg"
        case .sleeping, .idle: break // The original mouse-idle sleep sequence owns this transition.
        }
        if p != .asking && p != .compact && p != .error && p != .happy {
            if store.busyCount>=3 { s = "working"; file = "clawd-working-building.svg" }
            else if store.busyCount>=2 { s = "working"; file = "clawd-headphones-groove.svg" }
            if (store.focus?.agents.count ?? 0)>=2 { s = "juggling"; file = "clawd-working-juggling.svg" }
        }
        let script = "qishiState(\(NativePetWindow.json(s)),\(NativePetWindow.json(file)))"
        if script != lastState { lastState = script; clawd.receive(script,activity:activity) }
        else if let activity { clawd.receive("void 0",activity:activity) }
    }
}
