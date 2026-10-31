import AppKit
import WebKit

final class VerificationResources: NSObject, WKURLSchemeHandler {
    let root: URL
    init(_ root: URL) { self.root=root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url=task.request.url else { return }
        let file=root.appendingPathComponent(url.path)
        do {
            let data=try Data(contentsOf:file)
            let mime=["html":"text/html","js":"application/javascript","css":"text/css","png":"image/png","webp":"image/webp","svg":"image/svg+xml","mp3":"audio/mpeg"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data);task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// A real local WebKit renderer. Uses no account, app settings or running pet window.
@main struct CompanionWebTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                run()
                NSApp.terminate(nil)
            }
        }
        app.run()
    }
    @MainActor static func run() {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: CompanionWebTests <Resources> <snapshot folder>"); exit(2)
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(VerificationResources(resources), forURLScheme:"qishi-pet")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 260, height: 300), configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        let window = NSPanel(contentRect: web.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Claude companion verification"
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .floating
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        // Keep the nonactivating panel visible: occluded WebKit views throttle animation timers.
        window.orderFrontRegardless()
        func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        var checks = 0
        func require(_ ok: Bool, _ label: String) {
            if !ok { print("FAIL: \(label)"); fflush(stdout); window.close(); exit(1) }
            checks += 1; print("PASS: \(label)"); fflush(stdout)
        }
        func js(_ source: String) -> Any? {
            var done = false, value: Any?, error: Error?
            web.evaluateJavaScript(source) { result, failure in value = result; error = failure; done = true }
            let deadline = Date().addingTimeInterval(8)
            while !done && Date() < deadline { settle(0.015) }
            if !done || error != nil { print("JavaScript failure: \(source) — \(String(describing: error))"); fflush(stdout); window.close(); exit(1) }
            return value
        }
        func test(_ source: String, _ label: String) { require(js(source) as? Bool == true, label) }
        func awaitJS(_ source: String, timeout: Double = 8) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if js(source) as? Bool == true { return true }; settle(0.04) }
            return false
        }
        func snapshot(_ name: String) {
            var done = false, saved = false
            let config = WKSnapshotConfiguration(); config.snapshotWidth = 780
            web.takeSnapshot(with: config) { image, _ in
                if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: output.appendingPathComponent(name + ".png")); saved = true } catch {}
                }
                done = true
            }
            let deadline = Date().addingTimeInterval(8)
            while !done && Date() < deadline { settle(0.02) }
            require(saved, "snapshot \(name)")
        }
        web.load(URLRequest(url:URL(string:"qishi-pet://app/CrossPet/index.html")!))
        settle(0.6)
        require(awaitJS("window.qishiReady === true && typeof qishiInspect === 'function'"), "renderer initialized")
        settle(0.7)
        _ = js("setEggsEnabled(false);setTucked(null);setPose('idle',true)"); settle(0.4)
        test("typeof qishiMotionRenderer==='undefined'&&typeof qishiMotionData==='undefined'&&!document.getElementById('qishi-motion')", "no edge animation renderer is loaded")
        print("Initial diagnostics: \(js("JSON.stringify(qishiInspect())") ?? "nil")")
        for side in ["left", "right"] {
            // A hover request (peek=true) must behave exactly like a plain tuck.
            _ = js("setTucked('\(side)',true)"); settle(0.5)
            test("pose==='edge_\(side)'&&document.documentElement.classList.contains('tucked-\(side)')", "\(side) tucks with the static edge drawing")
            test("qishiInspect().img.file==='edge_\(side).webp'", "\(side) hover never swaps in the peek drawing")
            var files = Set<String>(), cuts = Set<String>(), oneSprite = true
            for _ in 0..<20 {
                settle(0.1)
                if let file = js("qishiInspect().img.file") as? String { files.insert(file) }
                if let cut = js("String(dockCut('\(side)'))") as? String { cuts.insert(cut) }
                oneSprite = oneSprite && js("document.querySelectorAll('#a.on,#b.on').length===1") as? Bool == true
            }
            require(oneSprite, "\(side) exactly one active sprite while tucked")
            require(files == ["edge_\(side).webp"], "\(side) tucked drawing stays unchanged over time")
            require(cuts.count == 1, "\(side) screen-edge cut stays fixed while tucked")
            test("qishiHitTest(0,0)===false", "\(side) transparent corner passes input through")
            snapshot(side + "-tucked")
            _ = js("setTucked(null)"); settle(0.5)
            test("!qishiInspect().img.file.startsWith('edge_')&&!document.documentElement.classList.contains('tucked')", "\(side) undocking restores a regular pose")
        }
        _ = js("setTucked('left')"); settle(0.3)
        _ = js("qishiDrag(true)"); settle(0.1)
        test("qishiInspect().dragging&&!document.documentElement.classList.contains('tucked')&&!qishiInspect().img.file.startsWith('dragging')", "dragging leaves the tuck and keeps normal artwork")
        _ = js("qishiDrag(false)")
        test("!qishiInspect().dragging&&qishiInspect().dragPhase==='idle'", "release completes immediately without landing playback")
        test("qishiInspect().dragAnimationEnabled===false", "dedicated drag animation is disabled")
        _ = js("setPose('thinking',true);window.__normalImage=currentUrl;qishiDrag(true)")
        test("currentUrl===__normalImage&&qishiInspect().displayPose===pose&&!currentUrl.includes('dragging')", "pickup does not replace the normal drawing")
        settle(1.2)
        test("currentUrl===__normalImage&&!qishiInspect().dragAnimationPending", "held drag has no sway animation")
        test("getComputedStyle(document.getElementById('body')).animationPlayState==='paused'", "normal body motion pauses while dragging")
        _ = js("qishiDrag(false)")
        test("currentUrl===__normalImage&&!document.documentElement.classList.contains('qishi-dragging')", "release resumes normal motion without landing artwork")
        test("(()=>{const before=currentUrl;for(let i=0;i<30;i++){qishiDrag(true);qishiDrag(false);}return currentUrl===before&&!qishiInspect().dragAnimationPending&&!qishiInspect().dragging;})()", "rapid re-grabs leave artwork unchanged and no drag timer")
        _ = js("setTucked('right');qishiHidden(true)"); settle(0.3)
        _ = js("qishiHidden(false)"); settle(0.3)
        test("pose==='edge_right'", "hiding and showing the page keeps the static tuck")
        _ = js("setTucked(null)"); settle(0.3)

        test("qishiErrors.length===0", "no JavaScript or resource errors")
        print("Final diagnostics: \(js("JSON.stringify(qishiInspect())") ?? "nil")")

        // Clawd's native panel is square (NativePetWindow baseSize 180×180).
        window.setContentSize(NSSize(width: 180, height: 180)); web.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
        web.load(URLRequest(url:URL(string:"qishi-pet://app/ClawdWeb/index.html")!))
        settle(0.6)
        require(awaitJS("window.qishiReady === true && typeof qishiInspect === 'function'"), "Clawd renderer initialized")
        // Drive the 30 Hz native tick from inside the page; __cursor/__moved stand in for the mouse.
        _ = js("window.__cursor=[90,60];window.__moved=false;window.__tick=setInterval(()=>{qishiPointer(__cursor[0],__cursor[1],__moved,true);__moved=false},33);window.__sounds=[];const __play=hostListeners.get('onPlaySound');hostListeners.set('onPlaySound',p=>{__sounds.push(p.url)});0")
        _ = js("window.__move=(x,y)=>{__cursor=[x,y];__moved=true};window.__claude=(states,events)=>qishiClaude(states.map((s,i)=>typeof s==='string'?{id:'s'+i,state:s,agents:0}:s),events);0")
        _ = js("__claude([],[])"); settle(0.3)

        // hit-renderer.js click accumulator: one click only resets, 2-3 poke, 4 flail.
        _ = js("qishiClick(30)"); settle(0.6)
        test("!isReacting", "Clawd single click plays no reaction (upstream reveals the session HUD only)")
        _ = js("qishiClick(30);qishiClick(30)"); settle(0.6)
        test("isReacting&&['clawd-react-annoyed.svg','clawd-react-left.svg'].includes(currentDisplayedSvg)", "Clawd double click pokes with annoyance or a left-side reaction")
        require(awaitJS("!isReacting", timeout: 5), "Clawd poke reaction ends")
        _ = js("for(let i=0;i<4;i++)qishiClick(150)"); settle(0.3)
        test("isReacting&&theme.reactions.double.files.includes(currentDisplayedSvg)", "Clawd four clicks flail")
        require(awaitJS("!isReacting", timeout: 5), "Clawd flail reaction ends")
        _ = js("__claude(['working'],['PreToolUse']);qishiClick(30);qishiClick(30)"); settle(0.6)
        test("!isReacting", "Clawd only reacts to clicks while idle")

        // state-visual-resolver.js working/juggling tiers and state.js min display.
        _ = js("window.__reset=()=>{clearPending();clearTimeout(autoReturnTimer);autoReturnTimer=null;stateChangedAt=0};__reset();__claude(['working'],['PreToolUse'])"); settle(0.3)
        test("currentDisplayedSvg==='clawd-working-typing.svg'", "one working session types")
        _ = js("__reset();__claude(['working','thinking'],['PreToolUse'])"); settle(0.3)
        test("currentDisplayedSvg==='clawd-headphones-groove.svg'", "two busy sessions switch to the second working tier")
        _ = js("__reset();__claude(['working','working','working'],['PreToolUse'])"); settle(0.3)
        test("currentDisplayedSvg==='clawd-working-building.svg'", "three busy sessions build")
        _ = js("__reset();__claude([{id:'a',state:'juggling',agents:1}],['SubagentStart'])"); settle(0.3)
        test("currentDisplayedSvg==='clawd-headphones-groove.svg'", "one subagent uses the first juggling tier")
        _ = js("__reset();__claude([{id:'a',state:'juggling',agents:2}],['SubagentStart'])"); settle(0.3)
        test("currentDisplayedSvg==='clawd-working-juggling.svg'", "two subagents juggle")
        _ = js("__reset();__claude([],['Stop']);window.__done=Date.now()"); settle(0.3)
        test("hostState==='attention'&&currentDisplayedSvg==='clawd-happy.svg'&&__sounds.length===1&&__sounds[0]==='sounds/complete.mp3'", "Stop flashes attention with the completion sound")
        _ = js("__claude(['thinking'],['UserPromptSubmit'])"); settle(0.3)
        test("hostState==='attention'", "attention holds its minimum display time")
        require(awaitJS("hostState==='thinking'&&Date.now()-__done>=3900", timeout: 6), "the queued state lands after the minimum display time")
        _ = js("__claude(['thinking'],['PermissionRequest'])"); settle(0.3)
        test("hostState==='thinking'", "thinking holds its one second minimum")
        require(awaitJS("hostState==='notification'&&currentDisplayedSvg==='clawd-notification.svg'", timeout: 3), "permission request flashes notification")
        test("__sounds.length===1", "the 10 s sound cooldown suppresses the confirm sound")
        _ = js("__reset();__claude([],['SessionEnd'])"); settle(0.3)
        test("hostState==='idle'&&currentDisplayedSvg==='clawd-idle-follow.svg'", "no sessions resolve to idle")

        // tick.js idle chain with shortened theme timings.
        _ = js("Object.assign(T,{mouseIdleTimeout:400,mouseSleepTimeout:1500,yawnDuration:400,deepSleepTimeout:2600,wakeDuration:400});__move(91,60)"); settle(0.2)
        require(awaitJS("hostState==='idle'&&theme.idleAnimations.some(a=>a.file===currentDisplayedSvg)", timeout: 3), "a still pointer plays one idle look")
        _ = js("__move(92,60)"); settle(0.2)
        test("currentDisplayedSvg==='clawd-idle-follow.svg'", "moving the pointer cuts the idle look short")
        require(awaitJS("hostState==='yawning'", timeout: 4), "a long still pointer yawns")
        require(awaitJS("hostState==='dozing'", timeout: 3), "yawning settles into dozing")
        require(awaitJS("hostState==='collapsing'", timeout: 4), "a dozing pet collapses after the deep sleep timeout")
        settle(0.6)
        test("hostState==='collapsing'", "collapse stays put without a theme collapse duration")
        _ = js("__move(40,40)"); settle(0.2)
        test("hostState==='waking'", "moving the pointer wakes a collapsed pet")
        require(awaitJS("hostState==='idle'", timeout: 2), "waking returns to the resolved state")
        _ = js("Object.assign(T,{mouseIdleTimeout:20000,mouseSleepTimeout:60000,yawnDuration:3000,deepSleepTimeout:600000,wakeDuration:1500});applyState('dozing')"); settle(0.8)
        _ = js("__move(41,40)"); settle(0.6)
        test("hostState==='idle'", "moving the pointer wakes a dozing pet straight to idle")

        // Spinning the cursor twice around the eyes makes Clawd dizzy, then cools down for 12 s.
        _ = js("window.__spin=(n)=>new Promise(done=>{let i=0;const r=clawdEl.getBoundingClientRect(),cx=r.x+r.width*theme.eyeTracking.eyeRatioX,cy=r.y+r.height*theme.eyeTracking.eyeRatioY;const t=setInterval(()=>{const a=i/12*Math.PI*2;__move(cx+50*Math.cos(a),cy+50*Math.sin(a));if(++i>n){clearInterval(t);done()}},40)});__spin(30);0"); settle(1.6)
        test("hostState==='dizzy'&&currentDisplayedSvg==='clawd-dizzy.svg'", "two cursor circles make Clawd dizzy")
        _ = js("applyState('idle');__spin(30);0"); settle(1.6)
        test("hostState==='idle'", "dizzy cools down before it can trigger again")

        // Do Not Disturb: falls asleep, ignores events, wakes on request.
        _ = js("qishiDnd(true)"); settle(0.2)
        test("hostState==='yawning'&&dndEnabled", "sleep (Do Not Disturb) starts with a yawn")
        require(awaitJS("hostState==='collapsing'", timeout: 4), "Do Not Disturb yawns straight into the collapse")
        _ = js("__claude(['working'],['PreToolUse']);__move(30,30)"); settle(0.4)
        test("hostState==='collapsing'", "Do Not Disturb ignores events and the pointer")
        _ = js("qishiDnd(false)"); settle(0.2)
        test("hostState==='waking'&&!dndEnabled", "waking Clawd plays the wake transition")
        require(awaitJS("hostState==='working'", timeout: 3), "after waking the current work shows")
        _ = js("__claude([],['SessionEnd'])"); settle(0.3)
        require(awaitJS("hostState==='idle'", timeout: 3), "Clawd returns to idle")
        _ = js("qishiDragDir('left')"); settle(0.3)
        test("isDragReacting", "dragging plays the drag reaction")
        _ = js("qishiDrag(false)"); settle(0.3)
        test("!isDragReacting&&currentDisplayedSvg==='clawd-idle-follow.svg'", "releasing the drag hands back the current state")

        _ = js("window.__drawn=()=>{const r=clawdEl.getBoundingClientRect(),s=clawdEl.tagName==='IMG'?r.width:Math.min(r.width,r.height);return [s,r.left+r.width/2,r.bottom-(r.height-s)/2]};0")
        for side in ["left", "right"] {
            _ = js("qishiMiniRestore('\(side)')"); settle(0.4)
            _ = js("window.__idle=__drawn();qishiTuck(null)"); settle(0.3)
            _ = js("qishiTuck('\(side)')"); settle(0.3)
            test("currentDisplayedSvg==='clawd-idle-follow.svg'&&_inMiniMode", "Clawd \(side) keeps its drawing while the window slides in")
            _ = js("qishiMiniEntered()"); settle(0.4)
            test("hostState==='mini-enter'", "Clawd \(side) plays mini-enter once in place")
            test("clawdEl.tagName==='IMG'&&__drawn().every((v,i)=>Math.abs(v-__idle[i])<0.5)", "Clawd \(side) mini-enter is drawn at exactly the mini-idle size and spot")
            _ = js("__claude(['working'],['PreToolUse'])"); settle(0.2)
            test("hostState==='mini-enter'", "Clawd \(side) drops state changes during the entry")
            require(awaitJS("hostState==='mini-idle'", timeout: 5), "Clawd \(side) rests in mini-idle after the entry")
            _ = js("__claude(['working'],['PostToolUse'])"); settle(0.3)
            test("hostState==='mini-working'", "Clawd \(side) shows work as mini-working")
            _ = js("qishiClick(20);qishiClick(20)"); settle(0.6)
            test("!isReacting&&hostState==='mini-working'", "Clawd \(side) tucked clicks play no reaction")
            _ = js("__claude([],['Stop'])"); settle(0.2)
            test("hostState==='mini-happy'", "Clawd \(side) completion maps to mini-happy")
            _ = js("__claude([],['SessionEnd'])"); settle(0.2)
            test("hostState==='mini-happy'", "Clawd \(side) mini-happy holds its minimum display time")
            require(awaitJS("hostState==='mini-idle'", timeout: 6), "Clawd \(side) mini-happy returns to mini-idle")
            _ = js("__claude([],['PermissionRequest'])"); settle(0.2)
            test("hostState==='mini-alert'", "Clawd \(side) permission request maps to mini-alert")
            _ = js("applyState('mini-idle')"); settle(0.2)
            _ = js("(()=>{for(let x=0;x<innerWidth;x+=2)for(let y=0;y<innerHeight;y+=2)if(qishiHitTest(x,y)){window.__over=[x,y];return}})()")
            _ = js("__move(__over[0],__over[1])"); settle(0.2)
            test("hostState==='mini-peek'&&qishiMiniPeek()", "Clawd \(side) peeks out under the pointer")
            _ = js("__move(-50,-50)"); settle(0.2)
            test("hostState==='mini-idle'&&!qishiMiniPeek()", "Clawd \(side) slides back when the pointer leaves")
            _ = js("qishiDnd(true)"); settle(0.2)
            test("hostState==='mini-sleep'", "Clawd \(side) Do Not Disturb sleeps in mini mode")
            _ = js("__move(__over[0],__over[1])"); settle(0.2)
            test("hostState==='mini-sleep'&&qishiMiniPeek()", "Clawd \(side) sleeping peek moves the window only")
            _ = js("qishiMiniExit();__move(-50,-50)"); settle(0.2)
            test("!qishiMiniPeek()", "Clawd \(side) never peeks during the exit jump")
            _ = js("qishiTuck(null)"); settle(0.3)
            test("hostState==='waking'&&!dndEnabled&&!_inMiniMode", "Clawd \(side) leaving the edge also ends Do Not Disturb")
            require(awaitJS("hostState==='idle'&&currentDisplayedSvg==='clawd-idle-follow.svg'", timeout: 3), "Clawd \(side) then resolves to idle with no sessions left")
        }
        _ = js("qishiCrabwalk('right')"); settle(0.3)
        test("hostState==='mini-crabwalk'&&_miniPreEntryMode&&!_inMiniMode", "menu entry crabwalks in the normal layout")
        _ = js("__claude(['working'],['PreToolUse'])"); settle(0.2)
        test("hostState==='mini-crabwalk'", "the crabwalk ignores state changes")
        _ = js("qishiTuck('right');qishiMiniEntered(300)"); settle(0.3)
        test("hostState==='mini-enter'&&_inMiniMode", "the menu jump lands in mini-enter")
        _ = js("qishiTuck(null);__claude([],['SessionEnd'])"); settle(0.3)
        _ = js("qishiMiniRestore('right')"); settle(0.3)
        test("hostState==='mini-idle'&&_inMiniMode", "Clawd restores straight into mini-idle at launch")
        _ = js("qishiTuck(null);clearInterval(__tick)"); settle(0.3)
        test("qishiErrors.length===0", "Clawd no JavaScript or resource errors")
        window.close()
        print("PASS: \(checks) real WKWebView checks completed")
    }
}
