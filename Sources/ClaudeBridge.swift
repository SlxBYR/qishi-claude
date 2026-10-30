import Foundation
import Darwin

enum ClaudeBridge {
    // This entry point runs before NSApplication is created; no UI or credentials are read.
    static func runIfNeeded() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--qishi-hook") || args.contains("--qishi-statusline") else { return false }
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 2_000_000, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            if args.contains("--qishi-statusline") {
                try ClaudeFiles.mutate { $0.statusline(input) }
                relayStatusline(data: data, input: input)
            } else if let i = args.firstIndex(of: "--qishi-hook"), args.count > i + 1 {
                let event = args[i + 1]
                try ClaudeFiles.mutate { $0.ingest(input, event: event) }
                if event == "PermissionRequest" { try permission(input) }
            }
        } catch { /* A companion must never break Claude's own permission flow. */ }
        return true
    }
    static func liveApp() -> Bool {
        guard let beat = ClaudeFiles.read([String: Double].self, at: ClaudeFiles.root.appendingPathComponent("heartbeat.json")),
              let ts = beat["time"], Date().timeIntervalSince1970 - ts < 4,
              let pid = beat["pid"], kill(Int32(pid), 0) == 0, beat["approvals"] == 1 else { return false }
        return true
    }
    static func permission(_ input: [String: Any]) throws {
        guard liveApp(), let sid = input["session_id"] as? String,
              let tool = input["tool_name"] as? String, !tool.isEmpty,
              !["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"].contains(tool),
              let params = input["tool_input"] as? [String: Any] else { return }
        let detail = try JSONSerialization.data(withJSONObject: params, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard detail.count <= 65_536 else { return } // Never approve a truncated request.
        let sessionID = ClaudeFiles.hash(sid)
        guard let session = ClaudeFiles.read(ClaudeState.self, at: ClaudeFiles.root.appendingPathComponent("claude-state.json"))?.sessions[sessionID] else { return }
        let id = UUID().uuidString
        let request = ClaudeRequest(id: id, session: sessionID, project: session.cwd, tool: tool,
                                    input: String(decoding: detail, as: UTF8.self), turn: session.turn,
                                    expires: Date().timeIntervalSince1970 + 90, pid: getpid())
        let requestURL = ClaudeFiles.root.appendingPathComponent("requests/\(id).json")
        let responseURL = ClaudeFiles.root.appendingPathComponent("responses/\(id).json")
        try ClaudeFiles.write(request, to: requestURL)
        defer { try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: responseURL) }
        while Date().timeIntervalSince1970 < request.expires && liveApp() && getppid() > 1 {
            let current = ClaudeFiles.read(ClaudeState.self, at: ClaudeFiles.root.appendingPathComponent("claude-state.json"))?.sessions[sessionID]
            guard current?.turn == request.turn, current?.closed == false, current?.pose != .happy else { return }
            if let result = ClaudeFiles.read([String: String].self, at: responseURL), result["id"] == id {
                guard let choice = result["choice"], ["allow", "deny"].contains(choice) else { return }
                var decision: [String: Any] = ["behavior": choice]
                if choice == "deny" { decision["message"] = "用户在栖时中拒绝了这一次操作。" }
                let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
                let bytes = try JSONSerialization.data(withJSONObject: output)
                FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
                return
            }
            usleep(150_000)
        }
        // No decision (closed, timed out, or unavailable) returns control to Claude.
    }
    static func relayStatusline(data: Data, input: [String: Any]) {
        let previous = ClaudeFiles.read([String: String].self, at: ClaudeFiles.root.appendingPathComponent("statusline-previous.json"))
        if let command = previous?["command"], !command.contains("--qishi-statusline") {
            // Use a temporary file for stdin: a large payload cannot deadlock a pipe writer.
            let temp = ClaudeFiles.root.appendingPathComponent("status-input-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try data.write(to: temp, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
                let handle = try FileHandle(forReadingFrom: temp); defer { try? handle.close() }
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]
                p.standardInput = handle; p.standardOutput = FileHandle.standardOutput; p.standardError = FileHandle.standardError
                try p.run()
                let deadline = Date().addingTimeInterval(3)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning { p.terminate() }
                return
            } catch { }
        }
        let model = (input["model"] as? [String: Any])?["display_name"] as? String ?? "Claude"
        let limits = input["rate_limits"] as? [String: Any] ?? [:]
        let parts = ["five_hour", "seven_day"].compactMap { key -> String? in
            guard let value = ClaudeState.percent((limits[key] as? [String: Any])?["used_percentage"]) else { return nil }
            return "\(key == "five_hour" ? "5h" : "7d") \(Int(value))% 已用"
        }
        print(([String(model.prefix(100))] + parts).joined(separator: " · "))
    }
}

enum ClaudeIntegration {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Stop", "StopFailure", "SessionEnd"]
    static func settings() throws -> [String: Any] {
        if !FileManager.default.fileExists(atPath: ClaudeFiles.settingsURL.path) { return [:] }
        guard let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeFiles.settingsURL)) as? [String: Any] else {
            throw NSError(domain: "Qishi", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude 设置文件格式不正确，未修改。"])
        }
        return dict
    }
    static var installed: Bool {
        guard let s = try? settings(), let hooks = s["hooks"] as? [String: [[String: Any]]] else { return false }
        return events.allSatisfy { event in
            (hooks[event] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("--qishi-hook \(event)") }
            }
        }
    }
    static func strip(_ hooks: [String: [[String: Any]]]) -> [String: [[String: Any]]] {
        var result = hooks
        for (event, entries) in hooks {
            result[event] = entries.compactMap { entry in
                guard let list = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = list.filter { !($0["command"] as? String ?? "").contains("--qishi-hook") }
                guard !kept.isEmpty else { return nil }
                var next = entry; next["hooks"] = kept; return next
            }
            if result[event]?.isEmpty == true { result.removeValue(forKey: event) }
        }
        return result
    }
    static func configure(install: Bool, executable: URL) throws {
        try ClaudeFiles.locked("integration") {
            let fm = FileManager.default
            var config = try settings()
            if let h = config["hooks"], !(h is [String: [[String: Any]]]) {
                throw NSError(domain: "Qishi", code: 2, userInfo: [NSLocalizedDescriptionKey: "Claude hooks 格式无法识别，已保留原文件。"])
            }
            let original = try? Data(contentsOf: ClaudeFiles.settingsURL)
            let backups = ClaudeFiles.root.appendingPathComponent("Backups")
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            if let original {
                let backup = backups.appendingPathComponent("settings-\(UUID().uuidString).json")
                try original.write(to: backup); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            var hooks = strip(config["hooks"] as? [String: [[String: Any]]] ?? [:])
            let previousURL = ClaudeFiles.root.appendingPathComponent("statusline-previous.json")
            let restoreURL = ClaudeFiles.root.appendingPathComponent("statusline-restore.json")
            let existingLine = config["statusLine"] as? [String: Any]
            let ownsLine = (existingLine?["command"] as? String ?? "").contains("--qishi-statusline")
            if install {
                let bridge = ClaudeFiles.root.appendingPathComponent("QishiBridge")
                let tmp = ClaudeFiles.root.appendingPathComponent("QishiBridge.new")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: executable, to: tmp)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
                guard rename(tmp.path, bridge.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                let base = ClaudeFiles.shellQuote(bridge.path)
                for event in events {
                    hooks[event, default: []].append(["matcher": "", "hooks": [["type": "command", "command": "\(base) --qishi-hook \(event)", "timeout": event == "PermissionRequest" ? 100 : 5]]])
                }
                if !ownsLine {
                    if let line = config["statusLine"] {
                        let bytes = try JSONSerialization.data(withJSONObject: ["value": line], options: [.sortedKeys])
                        try bytes.write(to: restoreURL, options: .atomic)
                    } else { try? fm.removeItem(at: restoreURL) }
                    if let line = existingLine, let command = line["command"] as? String, line["type"] as? String == "command" {
                        try ClaudeFiles.write(["command": command], to: previousURL)
                    } else { try? fm.removeItem(at: previousURL) }
                }
                var line = existingLine ?? [:]
                line["type"] = "command"; line["command"] = "\(base) --qishi-statusline"
                config["statusLine"] = line
            } else if ownsLine {
                if let data = try? Data(contentsOf: restoreURL), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    config["statusLine"] = saved["value"]
                } else { config.removeValue(forKey: "statusLine") }
            }
            if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
            // Detect edits made by another application while preparing the update.
            guard (try? Data(contentsOf: ClaudeFiles.settingsURL)) == original else {
                throw NSError(domain: "Qishi", code: 3, userInfo: [NSLocalizedDescriptionKey: "Claude 设置刚被其他程序更新，请重试。"])
            }
            try fm.createDirectory(at: ClaudeFiles.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: ClaudeFiles.settingsURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ClaudeFiles.settingsURL.path)
        }
    }
}
