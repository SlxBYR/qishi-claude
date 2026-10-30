import AppKit
import ApplicationServices

/// Reads the usage limits Claude Desktop shows on screen, through the macOS
/// Accessibility API, and only while Claude is running. No credentials, files
/// or network requests of Claude are touched. The last result is cached so it
/// stays visible after Claude quits.
@MainActor final class ClaudeDesktopReader: ObservableObject {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let interval: TimeInterval = 30
    @Published private(set) var snapshot: DesktopUsageSnapshot?
    @Published private(set) var running = false
    @Published private(set) var trusted = false
    let preview: Bool
    private var timer: Timer?
    private var reading = false
    private var observers: [NSObjectProtocol] = []
    private var cacheURL: URL { ClaudeFiles.root.appendingPathComponent("desktop-usage.json") }

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            snapshot = DesktopUsageSnapshot(quotas: [
                DesktopQuota(id: "five_hour", used: 18, reset: "Resets in 3 hr 12 min"),
                DesktopQuota(id: "seven_day", used: 42, reset: "Resets Thu 9:00 AM")], capturedAt: Date())
            running = true; trusted = true
        } else {
            snapshot = ClaudeFiles.read(DesktopUsageSnapshot.self, at: cacheURL)
        }
    }

    func start() {
        guard !preview, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
                Task { @MainActor in self?.refresh() }
            })
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    /// Shows the system Accessibility prompt; the user decides in System Settings.
    func requestAccess() {
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func refresh() {
        guard !preview else { return }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first { !$0.isTerminated }
        running = app != nil
        trusted = AXIsProcessTrusted()
        guard let pid = app?.processIdentifier, trusted, !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let found = DesktopUsageParser.parse(Self.visibleText(of: pid), at: Date())
            await MainActor.run { self.finish(found) }
        }
    }

    private func finish(_ found: DesktopUsageSnapshot?) {
        reading = false
        guard let found else { return }   // nothing on screen: keep the last reading
        snapshot = found
        try? ClaudeFiles.prepare()
        try? ClaudeFiles.write(found, to: cacheURL)
    }

    /// Text of Claude's windows in reading order. Electron exposes its web
    /// content to Accessibility only after AXManualAccessibility is set.
    nonisolated private static func visibleText(of pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        var lines: [String] = [], budget = 15_000
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 64, budget > 0 else { return }
            budget -= 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = copy(element, attribute) as? String, !text.isEmpty, text.count <= 200 { lines.append(text) }
            }
            for child in copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        for window in copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { visit(window, depth: 0) }
        return lines
    }
}
