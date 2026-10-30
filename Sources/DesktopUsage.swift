import Foundation

/// One usage limit as Claude Desktop displays it (Settings → Usage).
struct DesktopQuota: Codable, Identifiable, Equatable, Sendable {
    var id: String          // five_hour, seven_day, seven_day_opus, seven_day_sonnet
    var used: Double        // percent, 0...100
    var reset: String?      // the reset wording exactly as Claude shows it
}

/// The last limits read from Claude Desktop, kept across launches so the
/// workbench can show them while Claude is closed.
struct DesktopUsageSnapshot: Codable, Equatable, Sendable {
    var quotas: [DesktopQuota]
    var capturedAt: Date
}

/// Finds usage limits in the visible text of Claude Desktop's window, in
/// reading order. Only labelled limits with a percentage are kept; every other
/// line (conversation text included) is discarded by the caller.
enum DesktopUsageParser {
    private static let labels: [(id: String, pattern: String)] = [
        ("five_hour", #"current session|当前会话|当前时段|本次会话"#),
        ("seven_day", #"all models|所有模型|全部模型"#),
        ("seven_day_opus", #"\bopus\b"#),
        ("seven_day_sonnet", #"\bsonnet\b"#),
    ]
    private static let lookahead = 6

    static func parse(_ text: [String], at date: Date) -> DesktopUsageSnapshot? {
        var lines: [String] = []
        for raw in text {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty && line != lines.last { lines.append(line) }
        }
        var quotas: [DesktopQuota] = []
        for (index, line) in lines.enumerated() {
            guard let id = label(line), !quotas.contains(where: { $0.id == id }) else { continue }
            var used = percent(line), reset: String?
            for next in lines[(index + 1)..<min(lines.count, index + 1 + lookahead)] {
                if label(next) != nil { break }
                if used == nil { used = percent(next) }
                if reset == nil, next.count <= 60, matches(next, #"reset|重置"#) { reset = next }
            }
            if let used { quotas.append(DesktopQuota(id: id, used: used, reset: reset)) }
        }
        // A model name with a stray number is not the usage page.
        guard quotas.contains(where: { $0.id == "five_hour" || $0.id == "seven_day" }) else { return nil }
        return DesktopUsageSnapshot(quotas: quotas, capturedAt: date)
    }

    /// Short lines only: labels are headings, not sentences.
    private static func label(_ line: String) -> String? {
        guard line.count <= 40 else { return nil }
        return labels.first { matches(line, $0.pattern) }?.id
    }
    /// "15% used", "已使用 15%", or a bare "15%"; never a percentage inside prose.
    static func percent(_ line: String) -> Double? {
        guard line.count <= 40,
              let match = line.range(of: #"(\d{1,3}(?:\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        let rest = line.replacingCharacters(in: match, with: "").trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || matches(rest, #"^(used|已用|已使用|使用)$|^(已用|已使用)"#) || matches(line, #"\bused\b"#) else { return nil }
        let number = Double(line[match].filter { $0.isNumber || $0 == "." }) ?? -1
        return (0...100).contains(number) ? number : nil
    }
    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
