import AppKit
import Combine
import UserNotifications

struct ClaudePreferences: Codable {
    var showPet = true
    var approvals = false
    var notifications = false
    var alwaysOnTop = true
    var compact = false
    var petScale = 1.0
}
@MainActor final class ClaudeStore: ObservableObject {
    @Published var state = ClaudeState()
    @Published var requests: [ClaudeRequest] = []
    @Published var preferences = ClaudePreferences()
    @Published var connected = false
    @Published var message: String?
    @Published var selectedID: String?
    @Published var now = Date()
    let preview: Bool
    var onChange: (() -> Void)?
    var showMain: (() -> Void)?
    private var timer: Timer?
    private var notified = Set<String>()
    private var firstPoll = true
    private var tick = 0
    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            let time = Date().timeIntervalSince1970
            var first = ClaudeSession(id: "preview-one", cwd: "/Projects/栖时", model: "Claude Sonnet", pose: .writing, tool: "Edit", updated: time, toolCount: 12)
            first.quota = [ClaudeQuota(id: "five_hour", used: 28, resetsAt: time + 7200), ClaudeQuota(id: "seven_day", used: 46, resetsAt: time + 210000)]
            first.quotaUpdated = time; first.contextUsed = 34
            state.sessions[first.id] = first
            state.sessions["preview-two"] = ClaudeSession(id: "preview-two", cwd: "/Projects/网站", model: "Claude Opus", pose: .reading, tool: "Read", updated: time - 20, toolCount: 4)
            state.events = [ClaudeEvent(session: first.id, project: first.project, title: "编写代码", tool: "Edit", time: time)]
            connected = true
        } else {
            preferences = ClaudeFiles.read(ClaudePreferences.self, at: ClaudeFiles.root.appendingPathComponent("preferences.json")) ?? ClaudePreferences()
            connected = ClaudeIntegration.installed
        }
    }
    var sessions: [ClaudeSession] { state.sessions.values.sorted { $0.updated > $1.updated } }
    var live: [ClaudeSession] { sessions.filter { !$0.closed && !$0.stale(at: now.timeIntervalSince1970) && now.timeIntervalSince1970 - $0.updated < 3600 } }
    var busyCount: Int { live.filter { $0.pose.busy }.count }
    var focus: ClaudeSession? { sessions.first { $0.id == selectedID } ?? live.first ?? sessions.first }
    var pose: ClaudePose {
        if !requests.isEmpty || live.contains(where: { $0.pose == .asking }) { return .asking }
        if let s = live.first(where: { $0.pose.busy }) { return s.pose }
        if let s = live.first, now.timeIntervalSince1970 - s.updated < 15, [.happy, .error].contains(s.pose) { return s.pose }
        return (sessions.first.map { now.timeIntervalSince1970 - $0.updated > 600 } ?? false) ? .sleeping : .idle
    }
    func start() {
        guard !preview else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        guard !preview else { return }
        try? FileManager.default.removeItem(at: ClaudeFiles.root.appendingPathComponent("heartbeat.json"))
    }
    func poll() {
        now = Date(); tick += 1
        do {
            try ClaudeFiles.prepare()
            try ClaudeFiles.write(["time": now.timeIntervalSince1970, "pid": Double(getpid()), "approvals": preferences.approvals ? 1.0 : 0.0], to: ClaudeFiles.root.appendingPathComponent("heartbeat.json"))
            state = ClaudeFiles.read(ClaudeState.self, at: ClaudeFiles.root.appendingPathComponent("claude-state.json")) ?? ClaudeState()
            let files = try FileManager.default.contentsOfDirectory(at: ClaudeFiles.root.appendingPathComponent("requests"), includingPropertiesForKeys: nil)
            requests = files.filter { $0.pathExtension == "json" }.compactMap { url in
                guard let r = ClaudeFiles.read(ClaudeRequest.self, at: url), UUID(uuidString: r.id) != nil,
                      r.expires > now.timeIntervalSince1970, kill(r.pid, 0) == 0,
                      let s = state.sessions[r.session], s.turn == r.turn, !s.closed, s.pose != .happy else {
                    try? FileManager.default.removeItem(at: url); return nil
                }
                guard !FileManager.default.fileExists(atPath: ClaudeFiles.root.appendingPathComponent("responses/\(r.id).json").path) else { return nil }
                return r
            }.sorted { $0.expires < $1.expires }
            if firstPoll { notified = Set(state.events.map(\.id)); firstPoll = false }
            if preferences.notifications {
                for e in state.events where !notified.contains(e.id) && now.timeIntervalSince1970 - e.time < 15 {
                    if ["本轮完成", "遇到问题", "等你回应"].contains(e.title) { notify(title: "Claude · \(LT(e.title))", body: LT(e.project)) }
                }
            }
            notified.formUnion(state.events.map(\.id))
            if notified.count > 500 { notified = Set(state.events.map(\.id)) }
            if tick % 10 == 0 { connected = ClaudeIntegration.installed }
            onChange?()
        } catch { message = "Claude 状态读取失败：\(error.localizedDescription)" }
    }
    func save() {
        if !preview {
            do { try ClaudeFiles.prepare(); try ClaudeFiles.write(preferences, to: ClaudeFiles.root.appendingPathComponent("preferences.json")) }
            catch { message = "设置未能保存：\(error.localizedDescription)" }
        }
        onChange?()
    }
    func connect(_ enabled: Bool) {
        guard !preview, let exe = Bundle.main.executableURL else { return }
        do {
            try ClaudeIntegration.configure(install: enabled, executable: exe)
            connected = ClaudeIntegration.installed
            message = enabled ? "已接入。请重新打开 Claude Code 会话；若 Claude 提示信任钩子，请在 Claude 中确认。" : "已撤销栖时接入，其他钩子与设置已保留。请重新打开 Claude Code 会话。"
        } catch { message = "接入未完成：\(error.localizedDescription)" }
    }
    func decide(_ request: ClaudeRequest, choice: String) {
        guard !preview, ["allow", "deny", "native"].contains(choice), UUID(uuidString: request.id) != nil,
              request.expires > Date().timeIntervalSince1970, kill(request.pid, 0) == 0 else { return }
        do {
            try ClaudeFiles.write(["id": request.id, "choice": choice], to: ClaudeFiles.root.appendingPathComponent("responses/\(request.id).json"))
            requests.removeAll { $0.id == request.id }
        } catch { message = "回复未发送：\(error.localizedDescription)" }
    }
    func setNotifications(_ value: Bool) {
        guard !preview else { return }
        if !value { preferences.notifications = false; save(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.preferences.notifications = granted; self?.save()
                if !granted { self?.message = "通知未获授权，可在系统设置的通知中开启。" }
            }
        }
    }
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func openProject(_ session: ClaudeSession) {
        guard session.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: session.cwd) else { message = "此项目文件夹当前不可用。"; return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
    }
    func openClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
    }
}
