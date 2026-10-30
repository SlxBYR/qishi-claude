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
        window.close()
        print("PASS: \(checks) real WKWebView checks completed")
    }
}
