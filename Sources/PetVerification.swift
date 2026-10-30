import AppKit
import WebKit

@MainActor enum PetVerification {
    static func run(to folder: URL) {
        try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let pets = NativePets(persistent:false,showMain:{},hide:{ _ in })
        let store = ClaudeStore(preview:true)
        store.state = ClaudeState()
        pets.update(store)
        func settle(_ seconds: Double) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
        func expect(_ ok: Bool, _ message: String) {
            if !ok { print("FAIL: \(message)"); fflush(stdout); exit(1) }
            print("PASS: \(message)"); fflush(stdout)
        }
        func js(_ pet: NativePetWindow, _ source: String) -> Any? {
            var done = false, result: Any?, failure: Error?
            pet.web.evaluateJavaScript(source) { value,error in result = value; failure = error; done = true }
            let deadline = Date().addingTimeInterval(8)
            while !done && Date()<deadline { settle(0.02) }
            expect(done && failure == nil,"JavaScript: \(source.prefix(100))\(failure.map { " ERROR: \($0)" } ?? "")")
            return result
        }
        func snapshot(_ pet: NativePetWindow, _ name: String) {
            var done = false
            pet.web.takeSnapshot(with:nil) { image,error in
                if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) {
                    try? png.write(to:folder.appendingPathComponent(name+".png"))
                }
                done = true
            }
            let deadline=Date().addingTimeInterval(8)
            while !done && Date()<deadline { settle(0.02) }
        }
        let deadline=Date().addingTimeInterval(15)
        while (!pets.claude.ready || !pets.clawd.ready) && Date()<deadline { settle(0.1) }
        expect(pets.claude.ready && pets.clawd.ready,"both upstream renderers ready")
        settle(1)
        for pet in [pets.claude,pets.clawd] {
            expect(!pet.panel.isOpaque && !pet.panel.hasShadow && pet.panel.styleMask.contains(.borderless),"transparent borderless \(pet.kind.rawValue) window")
            expect(js(pet,"qishiHitTest(0,0)") as? Bool == false,"transparent corner passes clicks through")
        }
        expect((js(pets.claude,"qishiInspect().chrome") as? [String])?.isEmpty == true,"idle stays free of labels, bars and unsolicited bubbles")
        let stageBefore = js(pets.claude,"document.getElementById('stage').getBoundingClientRect().top") as? Double
        pets.claude.click(NSPoint(x:130,y:130),count:1); settle(0.4)
        expect(js(pets.claude,"qishiInspect().accountText") as? String == "请先设置账号注册时间","native click opens unconfigured account bubble")
        snapshot(pets.claude,"account-unconfigured")
        pets.update(store,registeredAt:Date().addingTimeInterval(-27*86400-3600)); settle(0.2)
        expect(js(pets.claude,"qishiInspect().accountText") as? String == "账号已存活 27 天","registration update reaches the visible bubble")
        expect(js(pets.claude,"document.getElementById('stage').getBoundingClientRect().top") as? Double == stageBefore,"opening bubble does not move the character")
        _ = js(pets.claude,"applyCharState('claude',{pose:'writing',event:'PreToolUse',ts:Date.now()/1000});say('');say('工作中')")
        expect(js(pets.claude,"qishiInspect().accountText") as? String == "账号已存活 27 天","work events and upstream speech cannot overwrite account age")
        expect(js(pets.claude,"(()=>{const r=document.getElementById('bubble').getBoundingClientRect();return qishiHitTest(r.x+r.width/2,r.y+r.height/2)})()") as? Bool == true,"visible bubble receives clicks")
        expect(js(pets.claude,"(()=>{const s=getComputedStyle(document.getElementById('bubble'));return s.borderRadius==='12px' && s.borderTopColor==='rgb(232, 163, 61)' && s.color==='rgb(74, 36, 24)'})()") as? Bool == true,"original CrossPet bubble shape and colors")
        for scale in [0.75,1.0,1.25] {
            pets.claude.present(show:true,scale:scale,onTop:true); settle(0.3)
            expect(js(pets.claude,"(()=>{const r=document.getElementById('bubble').getBoundingClientRect();return r.left>=0 && r.top>=0 && r.right<=innerWidth && r.bottom<=innerHeight})()") as? Bool == true,"bubble fits at scale \(scale)")
            snapshot(pets.claude,"account-\(scale)")
        }
        pets.claude.present(show:true,scale:1,onTop:true)
        pets.claude.web.appearance = NSAppearance(named:.darkAqua); settle(0.3)
        snapshot(pets.claude,"account-dark")
        pets.claude.web.appearance = NSAppearance(named:.aqua)
        _ = js(pets.claude,"(()=>{const r=document.getElementById('bubble').getBoundingClientRect();qishiClick(r.x+r.width/2,r.y+r.height/2)})()")
        expect(js(pets.claude,"qishiInspect().accountOpen") as? Bool == false,"clicking bubble dismisses it")
        for (age, expected) in [(3600.0,0),(86400.0,1),(12345.0*86400+3600,12345),(-86400.0,0)] {
            _ = js(pets.claude,"qishiUpdate({registeredAt:Date.now()/1000-(\(age))});qishiShowAccount()")
            expect(js(pets.claude,"qishiInspect().accountText") as? String == "账号已存活 \(expected) 天","elapsed whole days for \(age) seconds")
        }
        _ = js(pets.claude,"(()=>{const original=Date.now;const anchor=original();qishiUpdate({registeredAt:anchor/1000-86399});Date.now=()=>anchor+1000;say();Date.now=original})()")
        expect(js(pets.claude,"qishiInspect().accountText") as? String == "账号已存活 1 天","visible age rolls over after a full day")
        _ = js(pets.claude,"qishiUpdate({registeredAt:null})")
        expect(js(pets.claude,"qishiInspect().accountText") as? String == "请先设置账号注册时间","clearing registration removes previous count")
        pets.claude.beginDrag(); settle(0.1)
        expect(js(pets.claude,"qishiInspect().accountOpen") as? Bool == false,"drag dismisses the account bubble")
        expect(js(pets.claude,"qishiInspect().dragAssets.ready && qishiInspect().displayPose==='dragging' && active.complete && active.naturalWidth>0 && qishiInspect().img.file.startsWith('dragging-grab-')") as? Bool == true,"native drag starts with decoded pickup drawings")
        snapshot(pets.claude,"claude-dragging")
        var dragFrames = Set<String>()
        for _ in 0..<18 {
            settle(0.07)
            if let file = js(pets.claude,"qishiInspect().img.file") as? String { dragFrames.insert(file) }
        }
        expect(dragFrames.filter { $0.hasPrefix("dragging-sway-") }.count >= 10,"dense swing drawings advance without crossfading")
        expect(js(pets.claude,"getComputedStyle(active).transitionDuration==='0s' && document.querySelectorAll('#a.on,#b.on').length===1") as? Bool == true,"drag displays one opaque drawing without ghost images")
        _ = js(pets.claude,"qishiUpdate({state:{pose:'reading',event:'PreToolUse',ts:Date.now()/1000}})")
        settle(2.7)
        expect(js(pets.claude,"pose==='reading' && qishiInspect().displayPose==='dragging' && qishiInspect().img.file.startsWith('dragging')") as? Bool == true,"work updates are retained without replacing drag artwork")
        pets.claude.shake(); settle(0.15)
        expect(js(pets.claude,"pose==='dizzy' && qishiInspect().displayPose==='dragging' && qishiInspect().img.file.startsWith('dragging')") as? Bool == true,"shake reaction cannot replace drag artwork")
        pets.claude.endDrag()
        settle(0.25)
        expect(js(pets.claude,"!qishiInspect().dragging && qishiInspect().dragPhase==='drop' && qishiInspect().img.file.startsWith('dragging-drop-')") as? Bool == true,"release plays the drawn landing transition")
        settle(0.50)
        expect(js(pets.claude,"!qishiInspect().dragging && qishiInspect().dragPhase==='idle' && qishiInspect().img.file==='dizzy.webp'") as? Bool == true,"release preserves the pending shake reaction")
        settle(1.1)
        expect(js(pets.claude,"pose==='reading' && qishiInspect().img.file==='reading-2.webp'") as? Bool == true,"release resumes the latest work pose")
        pets.claude.showAccount(); settle(0.1)
        _ = js(pets.claude,"window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))")
        expect(js(pets.claude,"qishiInspect().accountOpen") as? Bool == false,"Escape dismisses the bubble")
        pets.claude.showAccount(); settle(8.3)
        expect(js(pets.claude,"qishiInspect().accountOpen") as? Bool == false,"bubble closes automatically after eight seconds")
        expect(js(pets.claude,"(()=>{const r=document.getElementById('bubble').getBoundingClientRect();return qishiHitTest(r.x+r.width/2,r.y+2)})()") as? Bool == false,"dismissed bubble area passes clicks through")
        let poses = ["idle","listening","thinking","reading","writing","running","searching","delegating","drawing","compact","asking","happy","proud","oops","sleeping","hum","stretch","yawn","clawd","busy_left","busy_right","swamped_left","swamped_right","annoyed","puffed","redhot","sulk","dizzy","coaxed","forgiven","greet_morning","fest_halloween"]
        for pose in poses {
            _ = js(pets.claude,"setPose(\(NativePetWindow.json(pose)),true)")
            settle(0.3)
            expect(js(pets.claude,"active.complete && active.naturalWidth>0 && pose===\(NativePetWindow.json(pose))") as? Bool == true,"CrossPet \(pose) original art and pose")
            if ["idle","writing","thinking","sleeping","proud","redhot","fest_halloween"].contains(pose) { snapshot(pets.claude,"claude-"+pose) }
        }
        _ = js(pets.claude,"setPose('writing',true)"); settle(0.4)
        let a = js(pets.claude,"getComputedStyle(document.getElementById('body')).transform") as? String
        settle(0.27)
        let b = js(pets.claude,"getComputedStyle(document.getElementById('body')).transform") as? String
        print("Motion samples: \(a ?? "nil") / \(b ?? "nil"); \(js(pets.claude,"JSON.stringify(document.getElementById('body').getAnimations().map(a=>({state:a.playState,time:a.currentTime})))") ?? "nil")")
        expect(a != b,"CrossPet body animation advances")
        expect(js(pets.claude,"document.getElementById('fx').querySelectorAll('svg').length>0") as? Bool == true,"original SVG effect plays with writing pose")
        _ = js(pets.claude,"setPose('idle',true);handleClick('pat')"); settle(0.4)
        expect(js(pets.claude,"pose==='pat'") as? Bool == true,"head-pat reaction")
        _ = js(pets.claude,"setTucked('left',true)"); settle(0.5)
        expect(js(pets.claude,"pose==='edge_left'") as? Bool == true,"Claude-chan tucks with the static edge art, never the peek")
        snapshot(pets.claude,"claude-edge"); _ = js(pets.claude,"setTucked(null)")
        _ = js(pets.claude,"shaken();shaken();shaken()"); settle(0.4)
        expect(js(pets.claude,"pose==='dizzy'") as? Bool == true,"shake reaction")
        let svgFolder=Bundle.main.resourceURL!.appendingPathComponent("ClawdWeb/assets")
        let files=(try! FileManager.default.contentsOfDirectory(atPath:svgFolder.path)).filter{$0.hasSuffix(".svg")}.sorted()
        for file in files {
            _ = js(pets.clawd,"qishiState('working',\(NativePetWindow.json(file)))")
            settle(0.2)
            let limit=Date().addingTimeInterval(3)
            var loaded=false
            repeat {
                loaded = js(pets.clawd,"currentDisplayedSvg===\(NativePetWindow.json(file)) && qishiInspect().loaded") as? Bool == true
                if !loaded { settle(0.15) }
            } while !loaded && Date()<limit
            if !loaded { print("Clawd diagnostics: \(js(pets.clawd,"JSON.stringify(qishiInspect())") ?? "none")") }
            expect(loaded,"Clawd original SVG: \(file)")
            if ["clawd-working-typing.svg","clawd-working-thinking.svg","clawd-sleeping.svg","clawd-working-juggling.svg"].contains(file) { snapshot(pets.clawd,file) }
        }
        _ = js(pets.clawd,"qishiState('idle','clawd-idle-follow.svg')"); settle(0.5)
        expect(js(pets.clawd,"qishiInspect().eyes") as? Bool == true,"Clawd original SVG eye targets attached")
        expect(js(pets.clawd,"qishiEmit('onEyeMove',2,1);eyeTarget.getAttribute('transform')") as? String == "translate(2, 1)","eye-follow transform")
        snapshot(pets.clawd,"clawd-idle")
        _ = js(pets.clawd,"qishiClick(20)"); settle(0.4)
        expect(js(pets.clawd,"isReacting") as? Bool == true,"Clawd click reaction")
        _ = js(pets.clawd,"qishiDrag(true)"); settle(0.3)
        expect(js(pets.clawd,"isDragReacting") as? Bool == true,"Clawd drag reaction")
        _ = js(pets.clawd,"qishiDrag(false);qishiTuck('right',true)"); settle(0.5)
        snapshot(pets.clawd,"clawd-edge")
        for pet in [pets.claude,pets.clawd] {
            expect((js(pet,"qishiErrors") as? [String])?.isEmpty == true,"\(pet.kind.rawValue) no rendering errors")
            pet.panel.orderOut(nil)
        }
        print("PASS: original animation verification complete, \(poses.count) Claude poses and \(files.count) Clawd SVGs")
    }
}
