import Foundation
import Combine

/// Daily token totals from Claude Code's local transcripts. Files are re-read
/// only when their size or modification time changes; everything stays local.
@MainActor final class TokenUsageStore: ObservableObject {
    /// 53 weeks: a full year of columns for the activity grid, plus the current week.
    nonisolated static let window = 371
    static let interval: TimeInterval = 120
    @Published private(set) var daily: [DailyTokens] = []
    @Published private(set) var updatedAt: Date?
    let preview: Bool
    private var cache: [String: CachedFile] = [:]
    private var scanning = false
    private var timer: Timer?

    struct CachedFile: Sendable { let size: Int; let modified: Date; let entries: [TokenUsageParser.Entry] }

    static var projectsURL: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("projects", isDirectory: true)
    }

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            // A plausible year: started a few months ago, weekday work, quiet weekends.
            let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
            daily = (0..<Self.window).reversed().compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                let weekend = calendar.isDateInWeekend(day), scale = weekend ? 0.15 : 0.6 + Double((offset * 37) % 50) / 100
                let idle = offset > 130 && offset % 41 != 0 || offset > 0 && (offset * 7) % 9 == 0
                let base = idle ? 0 : offset == 0 ? 0.45 : scale
                return DailyTokens(day: day, counts: TokenCounts(input: Int(42_000 * base), output: Int(160_000 * base),
                                                                 cacheWrite: Int(900_000 * base), cacheRead: Int(7_800_000 * base)))
            }
            updatedAt = Date()
        }
    }

    func start() {
        guard !preview, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard !preview, !scanning else { return }
        scanning = true
        let previous = cache, root = Self.projectsURL
        Task.detached(priority: .utility) {
            let (files, daily) = Self.scan(root: root, previous: previous)
            await MainActor.run {
                self.cache = files; self.daily = daily; self.updatedAt = Date(); self.scanning = false
            }
        }
    }

    nonisolated private static func scan(root: URL, previous: [String: CachedFile]) -> ([String: CachedFile], [DailyTokens]) {
        let since = Calendar.current.date(byAdding: .day, value: -(window + 1), to: Date()) ?? .distantPast
        var files: [String: CachedFile] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, let modified = values.contentModificationDate, modified >= since else { continue }
            if let cached = previous[url.path], cached.size == size, cached.modified == modified {
                files[url.path] = cached
            } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                files[url.path] = CachedFile(size: size, modified: modified, entries: TokenUsageParser.entries(fromJSONL: data, since: since))
            }
        }
        return (files, TokenUsageParser.daily(files.values.flatMap(\.entries), days: window))
    }
}
