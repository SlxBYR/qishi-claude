import Foundation

struct MonitorSettings: Codable, Equatable, Sendable {
    var email = ""
    var registeredAt: Date?
    var intervalMinutes = 5
    var monitoring = true
    var notify = false
    var hideDockIcon = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case email, registeredAt, intervalMinutes, monitoring, notify, hideDockIcon
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        registeredAt = try values.decodeIfPresent(Date.self, forKey: .registeredAt)
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
        monitoring = try values.decodeIfPresent(Bool.self, forKey: .monitoring) ?? true
        notify = try values.decodeIfPresent(Bool.self, forKey: .notify) ?? false
        hideDockIcon = try values.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
    }

    var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var isConfigured: Bool { Self.validEmail(normalizedEmail) && registeredAt != nil }
    static func validEmail(_ email: String) -> Bool {
        email.range(of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct MailHit: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var subject: String
    var sender: String
    var receivedAt: Date
}

struct MonitorSnapshot: Codable, Sendable {
    var email = ""
    var registeredAt: Date?
    var lastChecked: Date?
    var lastAttempt: Date?
    var error: String?
    var hits: [MailHit] = []
    var monitoring = true
    var intervalMinutes = 5
    var coveredFolders: [String] = []
    var notifiedIDs: [String] = []
    var isConfigured: Bool { !email.isEmpty && registeredAt != nil }
    func isStale(at now: Date) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) > Double(max(intervalMinutes * 3, 15) * 60)
    }
    func status(at now: Date) -> (title: String, symbol: String, tone: String) {
        if !isConfigured { return ("等待连接", "link", "neutral") }
        if !monitoring { return ("检测已暂停", "pause.circle", "neutral") }
        if error != nil { return ("检查未完成", "wifi.exclamationmark", "warning") }
        if lastChecked == nil { return ("等待首次检查", "clock", "neutral") }
        if isStale(at: now) { return ("结果待更新", "clock.badge.exclamationmark", "warning") }
        if !hits.isEmpty { return ("发现匹配邮件", "exclamationmark.envelope", "alert") }
        return ("未发现匹配邮件", "checkmark.circle", "good")
    }
}

struct Elapsed: Equatable {
    let days: Int
    let hours: Int
    let minutes: Int
    let seconds: Int
    init(since start: Date, now: Date) {
        let total = Int(max(0, now.timeIntervalSince(start)))
        days = total / 86400
        hours = (total % 86400) / 3600
        minutes = (total % 3600) / 60
        seconds = total % 60
    }
    var clock: String { String(format: "%02d : %02d : %02d", hours, minutes, seconds) }
}

enum MailRules {
    // Gmail performs full-text matching, including MIME-decoded bodies. The client
    // checks the actual From mailbox domain independently of display names.
    static func query(since date: Date) -> String {
        "in:anywhere from:(anthropic.com) suspended after:\(Int(date.timeIntervalSince1970) - 1)"
    }
    static func senderAddress(_ header: String) -> String? {
        let unfolded = header.replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        let candidate: String
        if let open = unfolded.lastIndex(of: "<"), let close = unfolded[open...].firstIndex(of: ">") {
            candidate = String(unfolded[unfolded.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        } else {
            candidate = unfolded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard MonitorSettings.validEmail(candidate) else { return nil }
        return candidate.lowercased()
    }
    static func isAnthropicSender(_ header: String) -> Bool {
        guard let address = senderAddress(header), let domain = address.split(separator: "@").last else { return false }
        return domain == "anthropic.com" || domain.hasSuffix(".anthropic.com")
    }
    static func headers(_ raw: String) -> [String: String] {
        let unfolded = raw.replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        var values: [String: String] = [:]
        for line in unfolded.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Multiple From headers are ambiguous; do not trust the last one.
            if values[key] != nil && key == "from" { values[key] = "invalid duplicate from" }
            else { values[key] = value }
        }
        return values
    }
    static func decodeHeader(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let normalized = value.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        var output = normalized
        for match in regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).reversed() {
            func part(_ index: Int) -> String { String(normalized[Range(match.range(at: index), in: normalized)!]) }
            let bytes: Data?
            if part(2).lowercased() == "b" { bytes = Data(base64Encoded: part(3)) }
            else {
                let input = Array(part(3).replacingOccurrences(of: "_", with: " ").utf8)
                var decoded: [UInt8] = []; var i = 0
                while i < input.count {
                    if input[i] == 61, i + 2 < input.count,
                       let hex = UInt8(String(bytes: input[(i+1)...(i+2)], encoding: .ascii) ?? "", radix: 16) {
                        decoded.append(hex); i += 3
                    } else { decoded.append(input[i]); i += 1 }
                }
                bytes = Data(decoded)
            }
            let encoding: String.Encoding = ["iso-8859-1", "latin1"].contains(part(1).lowercased()) ? .isoLatin1 : .utf8
            if let bytes, let text = String(data: bytes, encoding: encoding), let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: text)
            }
        }
        return output
    }
    static func internalDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
    static func gmailURL(email: String) -> URL {
        var parts = URLComponents(string: "https://mail.google.com/mail/u/")!
        parts.queryItems = [URLQueryItem(name: "authuser", value: email)]
        parts.fragment = "search/in:anywhere from:(anthropic.com) suspended"
        return parts.url!
    }
}

enum SharedSnapshotStore {
    static var groupID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "QishiAppGroup") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
    static func groupURL() -> URL? {
        guard let groupID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("snapshot.json")
    }
    static func read() -> MonitorSnapshot {
        guard let url = groupURL(), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(MonitorSnapshot.self, from: data) else { return MonitorSnapshot() }
        return value
    }
    static func write(_ value: MonitorSnapshot) throws {
        guard let url = groupURL() else { return }
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
