import Foundation

/// Token counts of one Claude reply, or a sum of replies.
struct TokenCounts: Codable, Equatable, Sendable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var total: Int { input + output + cacheWrite + cacheRead }
    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output,
                    cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
    /// Field-wise maximum: streamed copies of one reply only ever grow.
    func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input), output: max(output, other.output),
                    cacheWrite: max(cacheWrite, other.cacheWrite), cacheRead: max(cacheRead, other.cacheRead))
    }
}

struct DailyTokens: Identifiable, Equatable, Sendable {
    let day: Date           // local start of day
    var counts: TokenCounts
    var id: Date { day }
}

/// Reads token usage from Claude Code's local session transcripts
/// (`<config>/projects/**/*.jsonl`). Only the usage block, timestamp and
/// message identity of each reply are read; conversation text is never kept.
enum TokenUsageParser {
    struct Entry: Codable, Equatable, Sendable {
        let key: String     // message id + request id: one reply, wherever it was copied
        let time: Date
        let counts: TokenCounts
    }

    static func entries(fromJSONL data: Data, since: Date = .distantPast) -> [Entry] {
        var result: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap byte filter first: most lines carry no usage block.
            guard line.count < 2_000_000, line.range(of: Data("\"output_tokens\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String, let time = date(stamp), time >= since else { continue }
            func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let counts = TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                                     cacheWrite: count("cache_creation_input_tokens"), cacheRead: count("cache_read_input_tokens"))
            guard counts.total > 0 else { continue }
            let identity = (message["id"] as? String).map { $0 + ":" + ((object["requestId"] as? String) ?? "") }
                ?? (object["uuid"] as? String) ?? "\(stamp):\(counts.total)"
            result.append(Entry(key: identity, time: time, counts: counts))
        }
        return result
    }

    /// The last `days` local days, oldest first, zero-filled, each reply counted once.
    static func daily(_ entries: [Entry], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DailyTokens] {
        var replies: [String: Entry] = [:]
        for entry in entries {
            if let seen = replies[entry.key] {
                replies[entry.key] = Entry(key: entry.key, time: min(seen.time, entry.time), counts: seen.counts.merged(with: entry.counts))
            } else { replies[entry.key] = entry }
        }
        var byDay: [Date: TokenCounts] = [:]
        for entry in replies.values {
            let day = calendar.startOfDay(for: entry.time)
            byDay[day] = (byDay[day] ?? TokenCounts()) + entry.counts
        }
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DailyTokens(day: $0, counts: byDay[$0] ?? TokenCounts()) }
        }
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let whole = ISO8601DateFormatter()
    static func date(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }
}
