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
            let mime=["html":"text/html","js":"application/javascript","css":"text/css","png":"image/png","webp":"image/webp"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data);task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// A real local WebKit renderer. Uses no account, app settings or running pet window.
@main struct EdgeHoverWebTests {
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
            print("Usage: EdgeHoverWebTests <Resources> <snapshot folder>"); exit(2)
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
        window.title = "Claude edge animation verification"
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
        _ = js("setEggsEnabled(false);setTucked(null);setPose('idle',true);window.__assetCheck=null;Promise.all(['left','right'].map(side=>'../Claude/edge-hover/'+side+'-11.png').map(url=>{const image=new Image();image.src=url;return image.decode().then(()=>({url,w:image.naturalWidth,h:image.naturalHeight}));})).then(list=>window.__assetCheck=list).catch(e=>window.__assetCheck={error:String(e)});void 0")
        require(awaitJS("window.__assetCheck !== null"), "frame decode completed")
        test("Array.isArray(__assetCheck)&&__assetCheck.length===2&&__assetCheck.every(f=>f.w===640&&f.h===640)", "both stable transparent source drawings decode")
        require(awaitJS("qishiInspect().edgeHover.ready.left==='ready'&&qishiInspect().edgeHover.ready.right==='ready'"), "animation preloader owns both stable sources")
        require(awaitJS("qishiInspect().motionRenderer?.ready===true"), "GPU continuous renderer and all textures ready")
        print("Initial diagnostics: \(js("JSON.stringify(qishiInspect())") ?? "nil")")
        // Runtime state checks are intentionally independent from the frame scheduler implementation.
        for side in ["left", "right"] {
            _ = js("setTucked('\(side)',false)"); settle(0.35)
            _ = js("setTucked('\(side)',true)")
            var files = Set<String>()
            var oneSprite = true
            var fixedCut = true
            for _ in 0..<30 {
                settle(0.075)
                if let file = js("qishiInspect().img.file") as? String { files.insert(file) }
                oneSprite = oneSprite && js("document.querySelectorAll('#a.on,#b.on').length===1") as? Bool == true
                fixedCut = fixedCut && js("dockCut('\(side)')===\(side == "left" ? "0" : "260")") as? Bool == true
            }
            require(oneSprite, "\(side) exactly one active sprite throughout playback")
            require(fixedCut, "\(side) screen-edge cut is fixed throughout playback")
            require(files == Set([side + "-11.png"]), "\(side) uses one unchanged drawing throughout reveal")
            test("pose==='edge_\(side)_peek'", "\(side) maintains the hover pose")
            print("Dock diagnostics \(side): \(js("JSON.stringify({cut:dockCut('\(side)'),stage:document.getElementById('stage').getBoundingClientRect().toJSON(),wrap:document.getElementById('wrap').getBoundingClientRect().toJSON(),viewport:innerWidth,edge:qishiInspect().edgeHover})") ?? "nil")")
            test("dockCut('\(side)')===\(side == "left" ? "0" : "260")", "\(side) screen-edge cut remains fixed while artwork moves")
            test("qishiHitTest(0,0)===false", "\(side) transparent corner passes input through")
            require(awaitJS("qishiInspect().edgeHover.phase==='hold'"), "\(side) reaches the settled hover pose")
            snapshot(side + "-hover")
            _ = js("setTucked('\(side)',false)")
            let tuckedAgain = awaitJS("qishiInspect().edgeHover.phase==='rest'&&qishiInspect().edgeHover.frame===0&&qishiInspect().img.file==='\(side)-11.png'", timeout: 4)
            if !tuckedAgain { print("Exit diagnostics \(side): \(js("JSON.stringify(qishiInspect())") ?? "nil")") }
            require(tuckedAgain, "\(side) returns smoothly to the tucked frame")
            snapshot(side + "-tucked")
            _ = js("setTucked(null)"); settle(0.35)
        }
        _ = js("setTucked('left',true)"); settle(0.31)
        let beforeReverse = js("qishiInspect().img.file") as? String
        _ = js("setTucked('left',false)"); settle(0.10)
        _ = js("setTucked('left',true)"); settle(0.16)
        require(beforeReverse?.hasPrefix("left-") == true, "quick reversal begins on a drawn frame")
        test("pose==='edge_left_peek'&&qishiInspect().img.file.startsWith('left-')", "quick pointer reversal keeps the current hover sequence")
        _ = js("qishiDrag(true)"); settle(0.10)
        test("qishiInspect().dragging&&!qishiInspect().edgeHover.active&&!qishiInspect().img.file.startsWith('dragging')", "dragging leaves edge playback and retains normal artwork")
        settle(0.65)
        test("!qishiInspect().motionRenderer.enabled&&!qishiInspect().dragAnimationPending", "dragging schedules no artwork animation")
        _ = js("qishiDrag(false)")
        test("!qishiInspect().dragging&&qishiInspect().dragPhase==='idle'", "release completes immediately without landing playback")
        _ = js("setTucked('right',true)"); settle(0.4)
        _ = js("qishiHidden(true)")
        let hiddenFrame = js("qishiInspect().edgeHover.frame") as? Double
        settle(0.5)
        require(js("qishiInspect().edgeHover.frame") as? Double == hiddenFrame, "hidden page pauses the keyframe sequence")
        _ = js("qishiHidden(false)"); settle(0.35)
        require(js("qishiInspect().edgeHover.frame") as? Double != hiddenFrame, "visible page resumes the keyframe sequence")
        _ = js("setTucked(null)"); settle(0.5)
        test("!qishiInspect().img.file.startsWith('left-')&&!qishiInspect().img.file.startsWith('right-')", "undocking restores a regular pose")

        test("qishiInspect().dragAnimationEnabled===false", "dedicated drag animation is disabled")
        test("Object.keys(qishiMotionData.images).length===2&&Object.keys(qishiMotionData.pairs).length===0&&Object.keys(qishiMotionData.images).every(id=>/^(left|right)-11$/.test(id))", "GPU loads only two fixed drawings without independent-frame morphs")
        _ = js("setPose('thinking',true);window.__normalImage=currentUrl;qishiDrag(true)")
        test("currentUrl===__normalImage&&qishiInspect().displayPose===pose&&!currentUrl.includes('dragging')", "pickup does not replace the normal drawing")
        settle(1.2)
        test("currentUrl===__normalImage&&!qishiInspect().motionRenderer.enabled&&!qishiInspect().dragAnimationPending", "held drag has no sway animation or GPU playback")
        test("getComputedStyle(document.getElementById('body')).animationPlayState==='paused'", "normal body motion pauses while dragging")
        _ = js("qishiDrag(false)")
        test("currentUrl===__normalImage&&!document.documentElement.classList.contains('qishi-dragging')", "release resumes normal motion without landing artwork")
        test("(()=>{const before=currentUrl;for(let i=0;i<30;i++){qishiDrag(true);qishiDrag(false);}return currentUrl===before&&!qishiInspect().dragAnimationPending&&!qishiInspect().dragging;})()", "rapid re-grabs leave artwork unchanged and no drag timer")
        _ = js("setTucked('left',true)"); settle(0.4)
        test("qishiInspect().motionRenderer.rigged", "edge uses a continuous rig on one original drawing")
        test("(()=>{const c=document.getElementById('qishi-motion'),before=c.toDataURL(),state=qishiInspect().edgeHover;setTucked('left',false);return c.toDataURL()===before&&qishiInspect().edgeHover.frame===state.frame&&qishiInspect().edgeHover.velocity===state.velocity;})()", "hover reversal preserves exact pixels, position and velocity")
        _ = js("edgeHover.setPaused(true)")
        test("(()=>{const c=document.getElementById('qishi-motion'),r={x:40,y:65,width:180,height:180},pose={x:0,y:0,rotation:0,scale:1};for(const id of ['left-11','right-11']){qishiMotionRenderer.paintRig(id,r,pose,QishiMotion.edgeRig(1,0,false));const start=c.toDataURL();qishiMotionRenderer.paintRig(id,r,pose,QishiMotion.edgeRig(1,10,false));if(start!==c.toDataURL())return false;}return true;})()", "both rig cycles close on exactly the same pixels")
        test("(()=>{const c=document.getElementById('qishi-motion'),r={x:40,y:65,width:180,height:180},pose={x:0,y:0,rotation:0,scale:1};qishiMotionRenderer.paintRig('left-11',r,pose,QishiMotion.edgeRig(1,0,false));const still=c.toDataURL();for(const clock of [1,2,3,4,5,5.9]){qishiMotionRenderer.paintRig('left-11',r,pose,QishiMotion.edgeRig(1,clock,false));if(still!==c.toDataURL())return false;}return true;})()", "first six seconds stay still instead of repeatedly moving")
        test("(()=>{const c=document.getElementById('qishi-motion'),r={x:40,y:65,width:180,height:180},pose={x:0,y:0,rotation:0,scale:1},frames=[];for(const clock of [6,6.6,7.2,7.8,8.6]){qishiMotionRenderer.paintRig('left-11',r,pose,QishiMotion.edgeRig(1,clock,false));frames.push(c.toDataURL());}return new Set(frames).size>=3;})()", "one slow greeting has real continuous intermediate geometry")
        test("(()=>{const c=document.getElementById('qishi-motion'),r={x:40,y:65,width:180,height:180},pose={x:0,y:0,rotation:0,scale:1},copy=document.createElement('canvas');copy.width=c.width;copy.height=c.height;const ctx=copy.getContext('2d',{willReadFrequently:true}),ratio=c.width/innerWidth;for(const id of ['left-11','right-11']){const center=qishiMotionData.images[id].rig.faceCenter;const x=Math.floor((r.x+r.width*(center[0]-.10))*ratio),y=Math.floor((r.y+r.height*(center[1]-.07))*ratio),w=Math.floor(r.width*.20*ratio),h=Math.floor(r.height*.14*ratio);const crop=()=>{ctx.clearRect(0,0,copy.width,copy.height);ctx.drawImage(c,0,0);return Array.from(ctx.getImageData(x,y,w,h).data).join(',');};qishiMotionRenderer.paintRig(id,r,pose,QishiMotion.edgeRig(1,0,false));const still=crop();qishiMotionRenderer.paintRig(id,r,pose,QishiMotion.edgeRig(1,7.2,false));if(still!==crop())return false;}return true;})()", "both faces stay pixel-identical while only the hand and hair move")
        _ = js("edgeHover.setPaused(false);qishiDrag(true)")
        test("!qishiInspect().edgeHover.active&&!qishiInspect().motionRenderer.enabled", "drag removes edge presenter immediately")
        _ = js("qishiDrag(false);setTucked('right',false)")
        test("qishiInspect().edgeHover.active&&qishiInspect().edgeHover.side==='right'", "dropping at an edge activates its pose immediately")
        _ = js("setTucked(null)"); settle(0.3)

        test("qishiErrors.length===0", "no JavaScript or resource errors")
        print("Final diagnostics: \(js("JSON.stringify(qishiInspect())") ?? "nil")")
        window.close()
        print("PASS: \(checks) real WKWebView checks completed")
    }
}
