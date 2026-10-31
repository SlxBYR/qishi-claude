import AppKit
import Combine

/// Silently keeps the plan limits Claude Desktop records for its own usage
/// panel. Only while Claude Desktop runs, its `plan-usage-history.json` is
/// checked every 20 seconds and re-read when it changed; new readings are
/// added to a local copy. No network, no Accessibility, no window access,
/// nothing of Claude is written or read beyond that one file.
@MainActor final class DesktopUsageStore: ObservableObject {
    nonisolated static let bundleID = "com.anthropic.claudefordesktop"
    static let interval: TimeInterval = 20
    @Published private(set) var history = DesktopUsageHistory()
    @Published private(set) var running = false
    /// When Claude's file was last read successfully, this launch.
    @Published private(set) var checkedAt: Date?
    /// Claude's file exists but could not be read or understood.
    @Published private(set) var unreadable = false
    let preview: Bool
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var seen: (size: Int, modified: Date)?
    private var reading = false

    static var sourceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/plan-usage-history.json")
    }
    private var cacheURL: URL { ClaudeFiles.root.appendingPathComponent("desktop-usage-history.json") }

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            // A week of sparse readings: the 5-hour limit fills and resets, the weekly one climbs.
            let now = Date().timeIntervalSince1970
            history.samples = (0..<36).reversed().map { step in
                let time = now - Double(step) * 4.5 * 3600 - 600
                let five = Double((36 - step) * 17 % 70), week = Double(6 + (36 - step) * 3 / 2)
                return DesktopUsageSample(time: time, account: "preview", used: ["five_hour": five, "seven_day": week])
            }
            running = true; checkedAt = Date()
        } else {
            history = ClaudeFiles.read(DesktopUsageHistory.self, at: cacheURL) ?? DesktopUsageHistory()
        }
    }

    func start() {
        guard !preview, observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
                Task { @MainActor in self?.update() }
            })
        }
        update()
    }
    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        timer?.invalidate(); timer = nil
    }

    /// Follows Claude Desktop: the timer exists only while it runs.
    private func update() {
        running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains { !$0.isTerminated }
        if running {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.check() }
                }
                timer?.tolerance = 5
            }
            check()
        } else {
            timer?.invalidate(); timer = nil
            seen = nil
        }
    }

    private func check() {
        guard !preview, !reading else { return }
        // A missed termination notice must not keep the reads going.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).contains(where: { !$0.isTerminated }) else { update(); return }
        let url = Self.sourceURL
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return }   // not recorded yet
        if let seen, seen.size == size, seen.modified == modified { return }
        reading = true
        Task.detached(priority: .utility) {
            let found = (try? Data(contentsOf: url)).flatMap(DesktopUsageParser.samples(from:))
            await MainActor.run { self.finish(found, size: size, modified: modified) }
        }
    }

    private func finish(_ found: [DesktopUsageSample]?, size: Int, modified: Date) {
        reading = false
        guard let found else { unreadable = true; return }   // retried on the next check
        seen = (size, modified)
        unreadable = false; checkedAt = Date()
        var next = history
        guard next.merge(found) else { return }
        history = next
        try? ClaudeFiles.prepare()
        try? ClaudeFiles.write(next, to: cacheURL)
    }
}
