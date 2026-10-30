import AppKit
import Combine
import Security
import UserNotifications
import WidgetKit

enum PasswordStore {
    private static let service = "local.qishi.claude-companion.gmail"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func save(_ value: String, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "栖时 · Gmail 应用专用密码"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MailError.message("无法保存到钥匙串，请确认钥匙串已解锁。") }
        } else if status != errSecSuccess { throw MailError.message("无法更新钥匙串中的密码。") }
    }
    static func read(account: String) throws -> String {
        var item = query(account); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound {
            // Read the previous app's credential as a compatibility fallback. Never update or delete it.
            item[kSecAttrService as String] = "local.qishi.anthropic-watch.gmail"
            status = SecItemCopyMatching(item as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw MailError.message("尚未保存应用专用密码，或钥匙串访问被拒绝。请在“连接与计时”中重新保存。")
        }
        return value
    }
    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MailError.message("未能移除钥匙串凭据，请解锁钥匙串后重试。") }
    }
}

private struct SavedState: Codable {
    var settings: MonitorSettings
    var snapshot: MonitorSnapshot
}

@MainActor final class MonitorStore: ObservableObject {
    @Published private(set) var settings = MonitorSettings()
    @Published private(set) var snapshot = MonitorSnapshot()
    @Published var isChecking = false
    @Published var selectedPage = 2
    @Published var message: String?
    @Published var storageError: String?
    var onAppearanceChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var stateURL: URL
    let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QishiClaude", isDirectory: true)
        stateURL = folder.appendingPathComponent("state.json")
        if preview {
            settings.email = "preview@gmail.com"
            settings.registeredAt = Date().addingTimeInterval(-27 * 86400 - 8 * 3600 - 42 * 60)
            snapshot.email = settings.email; snapshot.registeredAt = settings.registeredAt
            snapshot.lastChecked = Date(); snapshot.coveredFolders = ["全部邮件", "垃圾邮件", "已删除邮件"]
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: stateURL.path) {
                let previous = folder.deletingLastPathComponent().appendingPathComponent("Qishi/state.json")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.copyItem(at: previous, to: stateURL) }
            }
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                settings = state.settings; snapshot = state.snapshot
            }
        } catch { storageError = "本地设置读取失败：\(error.localizedDescription)" }
    }
    func start() {
        guard !preview else { return }
        restartPolling()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        }
    }
    private func save() {
        snapshot.email = settings.normalizedEmail
        snapshot.registeredAt = settings.registeredAt
        snapshot.monitoring = settings.monitoring
        snapshot.intervalMinutes = settings.intervalMinutes
        guard !preview else { onStatusChange?(); return }
        do {
            let data = try JSONEncoder().encode(SavedState(settings: settings, snapshot: snapshot))
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            try SharedSnapshotStore.write(snapshot)
            storageError = nil
        } catch { storageError = "无法保存设置：\(error.localizedDescription)" }
        if SharedSnapshotStore.groupID != nil { WidgetCenter.shared.reloadTimelines(ofKind: "QishiWidget") }
        onStatusChange?()
    }
    func apply(email: String, password: String, registered: Date, interval: Int) throws {
        var updated = settings
        updated.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard MonitorSettings.validEmail(updated.email) else { throw MailError.message("请输入完整的 Gmail 邮箱地址。Google Workspace 邮箱也可使用。") }
        guard registered <= Date() else { throw MailError.message("注册时间不能晚于现在。") }
        guard [1, 5, 15, 30].contains(interval) else { throw MailError.message("请选择有效的检查间隔。") }
        let cleaned = password.filter { !$0.isWhitespace }
        if !cleaned.isEmpty {
            guard cleaned.count == 16, cleaned.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw MailError.message("请输入 Google 生成的 16 位应用专用密码，不能使用登录密码。") }
            try PasswordStore.save(cleaned, account: updated.email)
        } else { _ = try PasswordStore.read(account: updated.email) }
        let identityChanged = updated.email != settings.email || registered != settings.registeredAt
        if updated.email != settings.email && !settings.email.isEmpty { try PasswordStore.delete(account: settings.email) }
        updated.registeredAt = registered; updated.intervalMinutes = interval; updated.monitoring = true
        settings = updated
        if identityChanged { snapshot = MonitorSnapshot() }
        snapshot.error = nil
        save(); restartPolling(); selectedPage = 0
    }
    func saveRegistration(_ date: Date) throws {
        guard date <= Date() else { throw MailError.message("注册时间不能晚于现在。") }
        if settings.registeredAt != date { snapshot = MonitorSnapshot() }
        settings.registeredAt = date
        save(); restartPolling(); selectedPage = 0
    }
    func disconnect() throws {
        try PasswordStore.delete(account: settings.email)
        loop?.cancel(); generation = UUID(); isChecking = false
        let oldDate = settings.registeredAt
        settings.email = ""; settings.registeredAt = oldDate
        snapshot = MonitorSnapshot(); save()
        message = "已断开 Gmail，钥匙串凭据已移除。注册计时仍然保留。"
    }
    func setMonitoring(_ enabled: Bool) {
        settings.monitoring = enabled; save(); restartPolling()
    }
    func setHideDockIcon(_ enabled: Bool) { settings.hideDockIcon = enabled; save(); onAppearanceChange?() }
    func setNotifications(_ enabled: Bool) {
        guard enabled else { settings.notify = false; save(); return }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                settings.notify = allowed
                if !allowed { message = "通知未获授权。你可以在系统设置 → 通知 → 栖时中开启。" }
                save()
            } catch { message = "无法开启通知：\(error.localizedDescription)" }
        }
    }
    func restartPolling() {
        loop?.cancel(); generation = UUID(); isChecking = false
        guard settings.isConfigured, settings.monitoring else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                do { try await Task.sleep(for: .seconds(Double(self.settings.intervalMinutes * 60))) }
                catch { return }
            }
        }
    }
    func check() async {
        guard !preview, settings.isConfigured, !isChecking, settings.monitoring else { return }
        isChecking = true
        let version = generation
        let current = settings
        defer { if version == generation { isChecking = false; onStatusChange?() } }
        snapshot.lastAttempt = Date()
        do {
            let password = try PasswordStore.read(account: current.normalizedEmail)
            let result = try await GmailChecker.check(settings: current, password: password)
            guard version == generation, !Task.isCancelled else { return }
            snapshot.hits = result.hits
            snapshot.coveredFolders = result.folders
            snapshot.lastChecked = Date(); snapshot.error = nil
            if settings.notify {
                let unseen = result.hits.filter { !snapshot.notifiedIDs.contains($0.id) }
                if let newest = unseen.first {
                    let content = UNMutableNotificationContent()
                    content.title = L("栖时 · 发现 Anthropic 匹配邮件", "Qishi · Matching Anthropic email found")
                    content.body = L("\(current.normalizedEmail) 收到包含 suspended 的邮件。请打开 Gmail 核实。", "\(current.normalizedEmail) received an email mentioning “suspended”. Open Gmail to verify.")
                    content.sound = .default
                    do {
                        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "qishi-\(newest.id)", content: content, trigger: nil))
                        snapshot.notifiedIDs = Array((snapshot.notifiedIDs + unseen.map(\.id)).suffix(1000))
                    } catch { message = "邮件检测成功，但通知未能送达：\(error.localizedDescription)" }
                }
            }
        } catch {
            guard version == generation, !Task.isCancelled else { return }
            snapshot.error = error.localizedDescription
        }
        save()
    }
    func openGmail() { NSWorkspace.shared.open(MailRules.gmailURL(email: settings.normalizedEmail)) }
}
