import Foundation
import CryptoKit
import CoreFoundation
import Darwin

enum ClaudePose: String, Codable, CaseIterable {
    case idle, thinking, reading, writing, running, searching, delegating, asking, compact, happy, error, sleeping
    var title: String {
        switch self {
        case .idle: return "待命"; case .thinking: return "思考中"; case .reading: return "阅读文件"
        case .writing: return "编写代码"; case .running: return "运行命令"; case .searching: return "查找资料"
        case .delegating: return "协同工作"; case .asking: return "等你回应"; case .compact: return "整理上下文"
        case .happy: return "本轮完成"; case .error: return "遇到问题"; case .sleeping: return "休息中"
        }
    }
    var symbol: String {
        switch self {
        case .idle, .sleeping: return "moon.zzz"; case .thinking: return "ellipsis.bubble"
        case .reading: return "book"; case .writing: return "pencil.line"; case .running: return "terminal"
        case .searching: return "magnifyingglass"; case .delegating: return "person.2"; case .asking: return "hand.raised"
        case .compact: return "archivebox"; case .happy: return "checkmark.circle"; case .error: return "exclamationmark.triangle"
        }
    }
    var asset: String {
        switch self {
        case .thinking: return "thinking-2"; case .reading: return "reading-2"; case .happy: return "happy-2"
        case .error: return "oops"; case .sleeping: return "sleeping-2"; default: return rawValue
        }
    }
    var busy: Bool { ![.idle, .sleeping, .happy, .error, .asking].contains(self) }
    static func tool(_ name: String) -> ClaudePose {
        let t = name.lowercased()
        if t.contains("askuserquestion") || t == "exitplanmode" { return .asking }
        if ["web", "fetch", "search", "browse"].contains(where: t.contains) { return .searching }
        if ["read", "grep", "glob", "list", "view"].contains(where: t.contains) { return .reading }
        if ["write", "edit", "patch", "replace", "create"].contains(where: t.contains) { return .writing }
        if t == "agent" || t == "task" || t.contains("subagent") { return .delegating }
        return .running
    }
}
struct ClaudeQuota: Codable, Identifiable {
    var id: String
    var used: Double
    var resetsAt: Double?
    var title: String { id == "five_hour" ? "5 小时额度" : id == "seven_day" ? "每周额度" : "支出限额" }
}
struct ClaudeSession: Codable, Identifiable {
    var id: String
    var cwd = ""
    var model = ""
    var pose = ClaudePose.idle
    var event = ""
    var tool = ""
    var updated = Date().timeIntervalSince1970
    var started = Date().timeIntervalSince1970
    var turn = UUID().uuidString
    var toolCount = 0
    var activeTools: [String: String] = [:]
    var agents: [String] = []
    var quota: [ClaudeQuota] = []
    var quotaUpdated: Double?
    var contextUsed: Double?
    var cost: Double?
    var closed = false
    var project: String { cwd.isEmpty ? "Claude 会话" : URL(fileURLWithPath: cwd).lastPathComponent }
    func stale(at now: Double) -> Bool { now - updated > 300 && (pose.busy || pose == .asking) }
}
struct ClaudeEvent: Codable, Identifiable {
    var id = UUID().uuidString
    var session: String
    var project: String
    var title: String
    var tool: String
    var time: Double
    var hook: String? = nil
    var agents: Int? = nil
}
struct ClaudeState: Codable {
    var sessions: [String: ClaudeSession] = [:]
    var events: [ClaudeEvent] = []
    mutating func ingest(_ input: [String: Any], event: String, now: Double = Date().timeIntervalSince1970) {
        guard let raw = input["session_id"] as? String, !raw.isEmpty, raw.count < 512 else { return }
        let sid = ClaudeFiles.hash(raw)
        var s = sessions[sid] ?? ClaudeSession(id: sid, started: now)
        if let cwd = input["cwd"] as? String { s.cwd = String(cwd.prefix(4096)) }
        if let m = input["model"] as? String { s.model = String(m.prefix(128)) }
        let tool = String((input["tool_name"] as? String ?? "").prefix(128))
        let toolID = input["tool_use_id"] as? String ?? tool
        s.updated = now; s.event = event; s.closed = false
        switch event {
        case "SessionStart": s.pose = .idle
        case "UserPromptSubmit": s.pose = .thinking; s.toolCount = 0; s.activeTools = [:]; s.agents = []; s.turn = UUID().uuidString
        case "PreToolUse":
            s.activeTools[toolID] = tool; s.tool = tool; s.toolCount += 1; s.pose = .tool(tool)
        case "PermissionRequest": s.pose = .asking; s.tool = tool
        case "PostToolUse", "PostToolUseFailure":
            s.activeTools.removeValue(forKey: toolID)
            s.tool = s.activeTools.sorted(by: { $0.key < $1.key }).first?.value ?? ""
            s.pose = event == "PostToolUseFailure" ? .error : (!s.tool.isEmpty ? .tool(s.tool) : (s.agents.isEmpty ? .thinking : .delegating))
        case "Notification":
            let kind = input["notification_type"] as? String ?? ""
            if ["permission_prompt", "elicitation_dialog", "idle_prompt"].contains(kind) { s.pose = .asking }
        case "SubagentStart":
            if let id = input["agent_id"] as? String, !s.agents.contains(id) { s.agents.append(id) }; s.pose = .delegating
        case "SubagentStop":
            s.agents.removeAll { $0 == input["agent_id"] as? String }
            s.pose = s.agents.isEmpty ? (s.activeTools.isEmpty ? .thinking : .tool(s.tool)) : .delegating
        case "PreCompact": s.pose = .compact
        case "PostCompact": s.pose = .thinking
        case "Stop": s.pose = .happy; s.tool = ""; s.activeTools = [:]; s.agents = []
        case "StopFailure": s.pose = .error; s.activeTools = [:]; s.agents = []
        case "SessionEnd": s.closed = true; s.pose = .idle; s.activeTools = [:]; s.agents = []
        default: break
        }
        sessions[sid] = s
        events.append(ClaudeEvent(session: sid, project: s.project, title: s.pose.title, tool: tool, time: now, hook: event, agents: s.agents.count))
        events = Array(events.suffix(150))
        sessions = sessions.filter { now - $0.value.updated < 86400 }
        if sessions.count > 100 { sessions = Dictionary(uniqueKeysWithValues: sessions.values.sorted { $0.updated > $1.updated }.prefix(100).map { ($0.id, $0) }) }
    }
    mutating func statusline(_ input: [String: Any], now: Double = Date().timeIntervalSince1970) {
        guard let raw = input["session_id"] as? String, !raw.isEmpty else { return }
        let sid = ClaudeFiles.hash(raw)
        var s = sessions[sid] ?? ClaudeSession(id: sid, updated: now, started: now)
        if let m = input["model"] as? [String: Any] { s.model = String((m["display_name"] as? String ?? m["id"] as? String ?? "").prefix(128)) }
        if let cwd = input["cwd"] as? String { s.cwd = String(cwd.prefix(4096)) }
        s.contextUsed = Self.percent((input["context_window"] as? [String: Any])?["used_percentage"])
        if let n = (input["cost"] as? [String: Any])?["total_cost_usd"] as? Double, n.isFinite, n >= 0 { s.cost = n }
        if let limits = input["rate_limits"] as? [String: Any] {
            s.quota = ["five_hour", "seven_day", "spend_limit"].compactMap { key in
                guard let row = limits[key] as? [String: Any], let used = Self.percent(row["used_percentage"]) else { return nil }
                return ClaudeQuota(id: key, used: used, resetsAt: row["resets_at"] as? Double)
            }
            s.quotaUpdated = now
        } else { s.quota = []; s.quotaUpdated = nil }
        sessions[sid] = s
    }
    static func percent(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return max(0, min(100, n.doubleValue))
    }
}

struct ClaudeRequest: Codable, Identifiable {
    var id: String
    var session: String
    var project: String
    var tool: String
    var input: String
    var turn: String
    var expires: Double
    var pid: Int32
}
enum ClaudeFiles {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["QISHI_CLAUDE_HOME"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QishiClaude")
    }
    static var settingsURL: URL {
        let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        return (path.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")).appendingPathComponent("settings.json")
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func prepare() throws {
        for path in [root, root.appendingPathComponent("requests"), root.appendingPathComponent("responses")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func locked<T>(_ name: String = "state", _ action: () throws -> T) throws -> T {
        try prepare()
        let fd = open(root.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline { throw CocoaError(.fileLocking) }; usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    static func mutate(_ change: (inout ClaudeState) -> Void) throws {
        try locked {
            let url = root.appendingPathComponent("claude-state.json")
            var state = read(ClaudeState.self, at: url) ?? ClaudeState()
            change(&state); try write(state, to: url)
        }
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
