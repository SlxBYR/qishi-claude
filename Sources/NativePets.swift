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
        let mime = ["html":"text/html","js":"application/javascript","css":"text/css","svg":"image/svg+xml","webp":"image/webp","png":"image/png","json":"application/json","mp3":"audio/mpeg"][file.pathExtension] ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:mime.hasPrefix("text/") || file.pathExtension == "js" ? "utf-8" : nil))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor final class PetDragView: NSView {
    weak var owner: NativePetWindow?
    private var down = NSPoint.zero, origin = NSPoint.zero
    private var dragged = false, swingX: CGFloat = 0, direction: CGFloat = 0, lastX: CGFloat = 0
    private var swings: [Date] = [], lastShake = Date.distantPast
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { owner?.showAccount(); return true }
    override func mouseDown(with event: NSEvent) { down = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        guard owner?.allowsDrag != false else { return }
        if !dragged {
            guard abs(p.x-down.x)+abs(p.y-down.y)>3 else { return }
            dragged = true; owner?.beginDrag(dx:p.x-down.x); origin = window?.frame.origin ?? .zero; down = p
            swingX = p.x; direction = 0; swings = []; lastX = p.x
        }
        // Clawd turns with every horizontal step like upstream hit-renderer; only Claude-chan reacts to shaking.
        if owner?.kind == .clawd {
            if p.x != lastX { owner?.dragStep(p.x-lastX); lastX = p.x }
        } else if direction == 0 {
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
        defer { dragged = false }
        if dragged { owner?.endDrag(); return }
        if owner?.kind == .clawd {
            // macOS Ctrl-click is the right-click gesture; Cmd-click opens the dashboard (the main window here).
            let flags = event.modifierFlags
            if flags.contains(.control) && !flags.contains(.command) { owner?.showMenu(event, in:self); return }
            if flags.contains(.command) { owner?.showMain?(); return }
        }
        owner?.click(convert(event.locationInWindow, from:nil), count:event.clickCount)
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
    private var dock: String?, tucked = false, dockOut = false
    private var dockedAt = Date.distantPast, lastWork = Date.distantPast
    // Clawd's edge mode follows upstream mini.js: the window snaps when dragged past the
    // screen edge, slides into the half-hidden spot, peeks 25 px under the pointer and
    // jumps back along a parabola when clicked.
    private var mini: String?, miniPeek = false, miniMoving = false, preMini = NSPoint.zero
    private var miniTimer: Timer?, miniGeneration = 0, dragDirection: String?
    // Upstream's "Sleep (Do Not Disturb)" menu toggle and sound preference, Clawd only.
    private var dnd = false
    private var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey:"QishiClawdSoundMuted") }
        set { UserDefaults.standard.set(!newValue,forKey:"QishiClawdSoundMuted") }
    }
    private static let miniOffset: CGFloat = 0.486, peekOffset: CGFloat = 25
    private static let snapTolerance: CGFloat = 30, jumpPeak: CGFloat = 40
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
        config.mediaTypesRequiringUserActionForPlayback = [] // Clawd's completion and confirm sounds play on hook events.
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
        if persistent, kind == .clawd, let saved = UserDefaults.standard.dictionary(forKey:miniKey),
           let side = saved["edge"] as? String, let x = saved["x"] as? Double, let y = saved["y"] as? Double {
            mini = side; preMini = NSPoint(x:x,y:y)
            if let origin = miniOrigin() { panel.setFrameOrigin(origin) }
        }
        let page = kind == .claude ? "CrossPet" : "ClawdWeb"
        web.load(URLRequest(url:URL(string:"qishi-pet://bundle/\(page)/index.html")!))
        timer = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    deinit { timer?.invalidate(); slideTimer?.invalidate(); miniTimer?.invalidate() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("window.qishiReady === true") { [weak self] result, error in
            guard let self, result as? Bool == true, error == nil else { return }
            self.ready = true
            if self.kind == .clawd { self.run("qishiSound(\(self.soundOn))") }
            if let side = self.mini { self.run("qishiMiniRestore(\(Self.json(side)))") }
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
            if mini != nil, !miniMoving, let origin = miniOrigin() { miniTimer?.invalidate(); miniTimer = nil; panel.setFrameOrigin(origin) }
        }
        panel.level = onTop ? .floating : .normal
        if show {
            if !panel.isVisible { panel.orderFrontRegardless(); if ready { run("qishiHidden(false)") } }
        } else { cancelSlide(); if ready { run("qishiHidden(true)") }; panel.orderOut(nil) }
    }
    func receive(_ script: String, activity: Date?) {
        run(script)
        if let activity, activity>dockedAt { lastWork = activity }
        if kind == .claude, dock != nil {
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
        let hit = "qishiHitTest(\(local.x),\(local.y))"
        let script = kind == .clawd ? "\(pointer)[\(hit),qishiMiniPeek()]" : hit
        tickInFlight = true
        web.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            self.tickInFlight = false
            let result = value as? [Any]
            let inside = (result?.first ?? value) as? Bool == true
            self.panel.ignoresMouseEvents = !inside && !self.dragging
            if let peek = result?.last as? Bool { self.syncMiniPeek(peek) }
        }
        if dock != nil, dockOut, Date().timeIntervalSince(lastWork)>=10 { dockOut = false; applyDock() }
    }
    func click(_ p: NSPoint, count: Int) {
        let x = p.x/scale, y = (panel.frame.height-p.y)/scale
        if kind == .claude { revealAccountPosition() }
        // Upstream hit-renderer: a click in mini mode only leaves the edge, with no reaction.
        else if mini != nil { if !miniMoving { exitMini() }; return }
        run(kind == .claude ? "qishiClick(\(x),\(y))" : "qishiClick(\(x))")
    }
    var allowsDrag: Bool { mini == nil && !miniMoving }
    private var miniKey: String { frameKey+"-mini" }
    private func miniOrigin() -> NSPoint? {
        guard let side = mini, let vf = (panel.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let w = panel.frame.width, h = panel.frame.height
        var x = side == "left" ? vf.minX-(w*Self.miniOffset).rounded() : vf.maxX-(w*(1-Self.miniOffset)).rounded()
        if miniPeek { x += side == "left" ? Self.peekOffset : -Self.peekOffset }
        return NSPoint(x:x,y:min(max(panel.frame.minY,vf.minY),vf.maxY-h))
    }
    private func saveMini() {
        guard persistent else { return }
        if let side = mini { UserDefaults.standard.set(["edge":side,"x":Double(preMini.x),"y":Double(preMini.y)],forKey:miniKey) }
        else { UserDefaults.standard.removeObject(forKey:miniKey) }
    }
    // mini.js animateWindowX/animateWindowParabola: ease-out t*(2-t), plus an arc for jumps.
    private func animateMini(to target: NSPoint, duration: Double, arc: CGFloat = 0, done: (() -> Void)? = nil) {
        miniTimer?.invalidate()
        let start = panel.frame.origin, began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.miniTimer === timer else { timer.invalidate(); return }
                let t = min(1,(ProcessInfo.processInfo.systemUptime-began)/duration)
                let eased = CGFloat(t*(2-t)), lift = 4*arc*CGFloat(t*(1-t))
                self.panel.setFrameOrigin(NSPoint(x:(start.x+(target.x-start.x)*eased).rounded(),
                                                  y:(start.y+(target.y-start.y)*eased+lift).rounded()))
                if t>=1 { timer.invalidate(); self.miniTimer = nil; done?() }
            }
        }
        miniTimer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    private func neighbor(_ screen: NSScreen, left: Bool) -> Bool {
        let f = panel.frame
        return NSScreen.screens.contains { $0 !== screen && $0.frame.minY<f.maxY && $0.frame.maxY>f.minY &&
            (left ? abs($0.frame.maxX-screen.frame.minX)<2 : abs($0.frame.minX-screen.frame.maxX)<2) }
    }
    private func enterMini(_ side: String, viaMenu: Bool = false) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        if !viaMenu { preMini = panel.frame.origin }
        mini = side; miniPeek = false; miniMoving = true; miniGeneration += 1
        let generation = miniGeneration
        run("qishiTuck(\(Self.json(side)))")
        guard let target = miniOrigin() else { return }
        saveMini()
        guard viaMenu else {
            // Drag path: slide into place first, then play mini-enter in place.
            animateMini(to:target,duration:0.1) { [weak self] in
                guard let self, self.miniGeneration == generation else { return }
                self.miniMoving = false
                self.run("qishiMiniEntered()")
            }
            return
        }
        // Menu path: jump off screen, then reappear tucked after the 300 ms preload.
        let w = panel.frame.width
        let x = neighbor(screen,left:side == "left") ? target.x
            : side == "right" ? (NSScreen.screens.map(\.frame.maxX).max() ?? screen.frame.maxX)-1
            : (NSScreen.screens.map(\.frame.minX).min() ?? screen.frame.minX)-w+1
        animateMini(to:NSPoint(x:x,y:panel.frame.minY),duration:0.35,arc:Self.jumpPeak) { [weak self] in
            guard let self, self.miniGeneration == generation else { return }
            self.run("qishiMiniEntered(300)")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in
                guard let self, self.miniGeneration == generation, let origin = self.miniOrigin() else { return }
                self.panel.setFrameOrigin(origin); self.miniMoving = false
            }
        }
    }
    // enterMiniViaMenu(): crabwalk to the nearer edge at 0.12 px/ms, then the menu entry jump.
    private func enterMiniViaMenu() {
        guard mini == nil, !miniMoving, !dnd, let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame, f = panel.frame, w = f.width, edge = (w*0.25).rounded()
        let side = f.midX <= vf.midX ? "left" : "right", adjacent = neighbor(screen,left:side == "left")
        let edgeX = side == "right" ? (adjacent ? vf.maxX-w : vf.maxX-w+edge) : (adjacent ? vf.minX : vf.minX-edge)
        let walk = abs(f.minX-edgeX)/0.12/1000
        preMini = f.origin; miniMoving = true; miniGeneration += 1
        let generation = miniGeneration
        run("qishiCrabwalk(\(Self.json(side)))")
        animateMini(to:NSPoint(x:edgeX,y:min(max(f.minY,vf.minY),vf.maxY-f.height)),duration:max(walk,0.016))
        DispatchQueue.main.asyncAfter(deadline:.now()+walk+0.05) { [weak self] in
            guard let self, self.miniGeneration == generation else { return }
            self.enterMini(side,viaMenu:true)
        }
    }
    private func exitMini() {
        guard mini != nil, let vf = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        miniMoving = true; miniPeek = false; miniGeneration += 1
        run("qishiMiniExit()")
        // resolveExitRestingBounds(): back to where the drag ended, kept clear of the snap zone.
        let w = panel.frame.width, h = panel.frame.height, edge = (w*0.25).rounded()
        var x = min(max(preMini.x,vf.minX),vf.maxX-w)
        let y = min(max(preMini.y,vf.minY),vf.maxY-h)
        if x >= vf.maxX-w+edge-Self.snapTolerance { x = vf.maxX-w+edge-100 }
        if x <= vf.minX-edge+Self.snapTolerance { x = vf.minX-edge+Self.snapTolerance+100 }
        animateMini(to:NSPoint(x:x,y:y),duration:0.35,arc:Self.jumpPeak) { [weak self] in
            guard let self else { return }
            // Leaving mini mode also ends Do Not Disturb, like upstream exitMiniMode().
            self.mini = nil; self.miniMoving = false; self.dnd = false
            self.run("qishiTuck(null)")
            self.saveMini()
            if self.persistent { self.panel.saveFrame(usingName:self.frameKey) }
        }
    }
    private func syncMiniPeek(_ peek: Bool) {
        guard mini != nil, !miniMoving, peek != miniPeek else { return }
        miniPeek = peek
        if let target = miniOrigin() { animateMini(to:target,duration:0.2) }
    }
    @objc func showAccount() {
        guard kind == .claude else { click(NSPoint(x:panel.frame.width/2,y:panel.frame.height/2),count:1); return }
        revealAccountPosition()
        run("qishiClick()")
    }
    private func revealAccountPosition() {
        cancelSlide()
        if dock != nil {
            dock = nil; tucked = false; dockOut = false
            run("setTucked(null)")
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame, vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x:min(max(f.minX,vf.minX),vf.maxX-f.width),
                                     y:min(max(f.minY,vf.minY),vf.maxY-f.height)))
    }
    func shake() { run("shaken()") }
    func beginDrag(dx: CGFloat = 0) {
        cancelSlide()
        dragging = true; dock = nil; tucked = false; dockOut = false
        if kind == .claude { run("qishiDrag(true)") }
        else { dragDirection = dx<0 ? "left" : dx>0 ? "right" : nil; run("qishiDragDir(\(dragDirection.map(Self.json) ?? "null"))") }
    }
    func dragStep(_ dx: CGFloat) {
        let direction = dx<0 ? "left" : "right"
        guard direction != dragDirection else { return }
        dragDirection = direction
        run("qishiDragDir(\(Self.json(direction)))")
    }
    func endDrag() {
        dragging = false; dragDirection = nil
        run("qishiDrag(false)")
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = panel.frame, vf = screen.visibleFrame, reach = f.width*0.3
        func neighbor(_ left: Bool) -> Bool {
            NSScreen.screens.contains { $0 !== screen && $0.frame.minY<f.maxY && $0.frame.maxY>f.minY &&
                (left ? abs($0.frame.maxX-screen.frame.minX)<2 : abs($0.frame.minX-screen.frame.maxX)<2) }
        }
        if kind == .clawd {
            // checkMiniModeSnap(): snap once a quarter of the window is past the edge.
            let edge = (f.width*0.25).rounded()
            if f.minX >= vf.maxX-f.width+edge-Self.snapTolerance && !neighbor(false) { enterMini("right") }
            else if f.minX <= vf.minX-edge+Self.snapTolerance && !neighbor(true) { enterMini("left") }
            else { panel.setFrameOrigin(NSPoint(x:min(max(f.minX,vf.minX),vf.maxX-f.width),y:min(max(f.minY,vf.minY),vf.maxY-f.height))) }
            if persistent { panel.saveFrame(usingName:frameKey) }
            return
        }
        if f.midX-vf.minX<reach && !neighbor(true) { dock = "left" }
        else if vf.maxX-f.midX<reach && !neighbor(false) { dock = "right" }
        if dock != nil { dockedAt = Date(); dockOut = false; applyDock() }
        else {
            panel.setFrameOrigin(NSPoint(x:min(max(f.minX,vf.minX),vf.maxX-f.width),y:min(max(f.minY,vf.minY),vf.maxY-f.height)))
        }
        if persistent { panel.saveFrame(usingName:frameKey) }
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
        run("setTucked(\(hidden ? Self.json(side) : "null"))")
        slide(frame)
        if hidden {
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
        if kind == .clawd {
            // Upstream menu.js state group, then the sound toggle and Qishi's own entries.
            menu.autoenablesItems = false
            let miniItem = NSMenuItem(title:mini != nil ? L("退出极简模式", "Exit Mini Mode") : L("极简模式", "Mini Mode"),action:#selector(toggleMini),keyEquivalent:"")
            miniItem.isEnabled = !miniMoving && (mini != nil || !dnd)
            let sleepItem = NSMenuItem(title:dnd ? L("唤醒 Clawd", "Wake Clawd") : L("休眠（免打扰）", "Sleep (Do Not Disturb)"),action:#selector(toggleDnd),keyEquivalent:"")
            let sound = NSMenuItem(title:L("音效", "Sound Effects"),action:#selector(toggleSound),keyEquivalent:"")
            sound.state = soundOn ? .on : .off
            for item in [miniItem,sleepItem] { item.target = self; menu.addItem(item) }
            menu.addItem(.separator()); sound.target = self; menu.addItem(sound); menu.addItem(.separator())
            for (title, action) in [(L("隐藏 Clawd", "Hide Clawd"),#selector(hidePet)),(L("打开栖时", "Open Qishi"),#selector(openMain)),(L("退出", "Quit"),#selector(quit))] {
                let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu,with:event,for:view)
            return
        }
        if kind == .claude {
            let item = NSMenuItem(title:L("账号存活天数", "Account Age"),action:#selector(showAccount),keyEquivalent:"")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }
        for (title, action) in [(L("摸摸头", "Pat"),#selector(pat)),(L("戳一下", "Poke"),#selector(poke)),(L("隐藏 Claude 娘", "Hide Claude-chan"),#selector(hidePet)),(L("打开栖时", "Open Qishi"),#selector(openMain)),(L("退出", "Quit"),#selector(quit))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:view)
    }
    @objc private func pat() { run("handleClick('pat')") }
    @objc private func poke() { run("handleClick('poke')") }
    @objc private func openMain() { showMain?() }
    @objc private func toggleMini() { if mini != nil { if !miniMoving { exitMini() } } else { enterMiniViaMenu() } }
    @objc private func toggleDnd() { dnd.toggle(); run("qishiDnd(\(dnd))") }
    @objc private func toggleSound() { soundOn.toggle(); run("qishiSound(\(soundOn))") }
    @objc private func hidePet() { hide?() }
    @objc private func quit() {
        guard kind == .claude else { NSApp.terminate(nil); return }
        run("farewell('',2000)")
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { NSApp.terminate(nil) }
    }
    static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys])
        return String(data:data,encoding:.utf8)!
    }
}

@MainActor final class NativePets {
    let claude: NativePetWindow, clawd: NativePetWindow
    private var lastPayload = "", lastState = "", seenEvents: Set<String>?
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
        let fresh = store.limits.filter { store.now.timeIntervalSince1970-$0.updated<900 }
        if !fresh.isEmpty { payload["quota"] = ["low":fresh.contains{$0.used>=90}] }
        let json = NativePetWindow.json(payload)
        let activity = live.contains{$0.pose.busy || $0.pose == .asking} ? Date() : live.first.map{Date(timeIntervalSince1970:$0.updated)}
        if json != lastPayload { lastPayload = json; claude.receive("qishiUpdate(\(json))",activity:activity) }
        else if let activity { claude.receive("void 0",activity:activity) }
        // Clawd resolves its own state like upstream state.js: per-session states plus the hook events since last time.
        let sessions: [[String:Any]] = live.sorted { $0.id < $1.id }.map { s in
            let state: String
            switch s.pose {
            case .thinking: state = "thinking"
            case .reading, .writing, .running, .searching: state = "working"
            case .delegating: state = "juggling"
            default: state = "idle" // One-shot outcomes (done, error, asking, compact) leave the session idle.
            }
            return ["id":s.id,"state":state,"agents":s.agents.count]
        }
        if seenEvents == nil { seenEvents = Set(store.state.events.map(\.id)) }
        let hooks = store.state.events.filter { !seenEvents!.contains($0.id) }.compactMap(\.hook)
        seenEvents = Set(store.state.events.map(\.id))
        let snapshot = NativePetWindow.json(sessions)
        if !hooks.isEmpty || snapshot != lastState {
            lastState = snapshot
            clawd.receive("qishiClaude(\(snapshot),\(NativePetWindow.json(hooks)))",activity:nil)
        }
    }
}
