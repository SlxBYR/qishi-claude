import AppKit

@main struct NativeMotionTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { fatalError("A desktop session is required") }
        let pet = NativePetWindow(kind:.claude,persistent:false)
        let area = screen.visibleFrame
        func wait(_ seconds: Double) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
        func expect(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        pet.beginDrag()
        pet.panel.setFrameOrigin(NSPoint(x:area.minX-100,y:area.minY+100))
        pet.endDrag()
        var previous = pet.panel.frame.minX
        for _ in 0..<10 {
            wait(0.02)
            let x = pet.panel.frame.minX
            expect(x>=previous-0.1 && x<=area.minX+0.1,"native docking advances without reversing")
            previous = x
        }
        expect(previous>area.minX-100,"native docking actually advances")
        // The drag takes control while the slide and its deferred measurement exist.
        pet.beginDrag()
        let grabbed = NSPoint(x:area.midX-130,y:area.midY-150)
        pet.panel.setFrameOrigin(grabbed)
        wait(0.8)
        expect(pet.panel.frame.origin==grabbed,"drag ownership cancels native slide and stale docking work")
        pet.panel.close()
        // Clawd follows upstream mini.js: snap past the edge, no drag while tucked, click jumps back.
        let clawd = NativePetWindow(kind:.clawd,persistent:false)
        let w = clawd.panel.frame.width
        clawd.beginDrag()
        let release = NSPoint(x:area.maxX-w*0.7,y:area.minY+120)
        clawd.panel.setFrameOrigin(release)
        clawd.endDrag()
        wait(0.3)
        expect(abs(clawd.panel.frame.minX-(area.maxX-(w*(1-0.486)).rounded()))<1,"Clawd snaps into the half-hidden mini spot")
        expect(!clawd.allowsDrag,"Clawd cannot be dragged while tucked")
        clawd.click(NSPoint(x:w/2,y:w/2),count:1)
        var peak = clawd.panel.frame.minY
        for _ in 0..<12 { wait(0.03); peak = max(peak,clawd.panel.frame.minY) }
        wait(0.3)
        expect(peak>release.y+20,"Clawd jumps back along an arc")
        expect(clawd.allowsDrag && clawd.panel.frame.maxX<=area.maxX+0.5 && clawd.panel.frame.minY==release.y,"Clawd lands back on screen at the release height")
        clawd.beginDrag()
        clawd.panel.setFrameOrigin(NSPoint(x:area.maxX-w*0.95,y:area.minY+120))
        clawd.endDrag()
        wait(0.3)
        expect(clawd.allowsDrag && clawd.panel.frame.maxX<=area.maxX+0.5,"a short overhang does not snap")
        // Menu entry: crabwalk to the nearer edge, jump off screen, then reappear tucked.
        clawd.panel.setFrameOrigin(NSPoint(x:area.maxX-w-60,y:area.minY+120))
        clawd.perform(NSSelectorFromString("toggleMini"))
        expect(!clawd.allowsDrag,"menu entry locks dragging while it walks")
        var offscreen = false
        for _ in 0..<80 { wait(0.03); offscreen = offscreen || clawd.panel.frame.minX>=area.maxX-1 }
        wait(0.5)
        expect(offscreen,"menu entry jumps fully off screen first")
        expect(abs(clawd.panel.frame.minX-(area.maxX-(w*(1-0.486)).rounded()))<1,"menu entry reappears in the mini spot")
        clawd.perform(NSSelectorFromString("toggleMini"))
        wait(0.6)
        expect(clawd.allowsDrag && clawd.panel.frame.maxX<=area.maxX+0.5,"exit from the menu jumps back on screen")
        clawd.panel.close()
        print("PASS: native motion regression tests complete")
    }
}
