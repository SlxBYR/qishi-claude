import Foundation
import CryptoKit

/// One reading of the plan limits, as Claude Desktop itself recorded it.
struct DesktopUsageSample: Codable, Equatable, Sendable {
    var time: Double                // seconds since 1970
    var account: String             // short hash of the organization id, never the id itself
    var used: [String: Double]      // five_hour, seven_day, or Claude's own key when unknown
}

/// Every reading kept so far. Claude Desktop trims its own file; this copy
/// lives in Qishi's data directory and survives that.
struct DesktopUsageHistory: Codable, Equatable, Sendable {
    static let keepDays: Double = 400
    static let cap = 20_000
    var samples: [DesktopUsageSample] = []

    var latest: DesktopUsageSample? { samples.last }
    /// Readings of the latest account since `since`, oldest first.
    func recent(since: Double) -> [DesktopUsageSample] {
        guard let account = latest?.account else { return [] }
        return samples.filter { $0.account == account && $0.time >= since }
    }
    /// Adds readings not seen before; true when anything changed.
    @discardableResult mutating func merge(_ found: [DesktopUsageSample], now: Double = Date().timeIntervalSince1970) -> Bool {
        var seen = Set(samples.map { "\($0.account):\($0.time)" })
        let fresh = found.filter { seen.insert("\($0.account):\($0.time)").inserted }
        let oldest = now - Self.keepDays * 86_400
        let before = samples.count
        samples = (samples + fresh).filter { $0.time >= oldest }.sorted { $0.time < $1.time }.suffix(Self.cap).map { $0 }
        return !fresh.isEmpty || samples.count != before
    }
}

/// Reads `plan-usage-history.json`, the file Claude Desktop writes for its own
/// usage panel. Only times, percentages and a hash of the organization id are
/// kept; the format is Claude's own, so anything unexpected is skipped.
enum DesktopUsageParser {
    static let keys = ["fh": "five_hour", "sd": "seven_day"]

    static func samples(from data: Data) -> [DesktopUsageSample]? {
        guard data.count < 8_000_000, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["samples"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            // Milliseconds since 1970, within a sane range (2020 … 2100).
            guard let ms = (row["t"] as? NSNumber)?.doubleValue, ms > 1.5e12, ms < 4.2e12,
                  let usage = row["u"] as? [String: Any] else { return nil }
            var used: [String: Double] = [:]
            for (key, value) in usage {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1000, key.count <= 32 else { continue }
                used[keys[key] ?? key] = number.doubleValue
            }
            guard !used.isEmpty else { return nil }
            return DesktopUsageSample(time: (ms / 1000).rounded(), account: account(row["org"] as? String), used: used)
        }
    }

    static func account(_ org: String?) -> String {
        guard let org, !org.isEmpty else { return "" }
        return SHA256.hash(data: Data(org.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// One limit as the workbench shows it: the freshest reading of either source.
struct MergedLimit: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case claudeCode, claudeDesktop }
    var id: String
    var used: Double
    var resetsAt: Double?
    var updated: Double
    var source: Source
}

enum LimitMerger {
    static let order = ["five_hour", "seven_day", "spend_limit"]

    /// Claude Code reports reset times, Claude Desktop records only percentages.
    /// A Desktop reading inherits Claude Code's reset time only when it falls
    /// inside that same window.
    static func merge(code: [(id: String, used: Double, resetsAt: Double?)], codeUpdated: Double?,
                      desktop: DesktopUsageSample?) -> [MergedLimit] {
        var result: [String: MergedLimit] = [:]
        if let codeUpdated {
            for row in code { result[row.id] = MergedLimit(id: row.id, used: row.used, resetsAt: row.resetsAt, updated: codeUpdated, source: .claudeCode) }
        }
        if let desktop {
            for (id, used) in desktop.used {
                if let current = result[id], current.updated >= desktop.time { continue }
                let reset = result[id].flatMap { code in code.resetsAt.flatMap { $0 > desktop.time ? $0 : nil } }
                result[id] = MergedLimit(id: id, used: used, resetsAt: reset, updated: desktop.time, source: .claudeDesktop)
            }
        }
        return result.values.sorted {
            let a = order.firstIndex(of: $0.id) ?? order.count, b = order.firstIndex(of: $1.id) ?? order.count
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
