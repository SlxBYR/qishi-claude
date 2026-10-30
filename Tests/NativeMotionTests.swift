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
        print("PASS: native motion regression tests complete")
    }
}
