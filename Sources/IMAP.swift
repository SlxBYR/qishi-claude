import Foundation
import Network

enum MailError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct IMAPPart: Sendable {
    var line: String
    var literal: Data?
}

enum IMAPParser {
    static func quoted(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 || $0.value == 0 }) else {
            throw MailError.message("输入中含有不支持的换行字符。")
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    static func mailbox(_ part: IMAPPart) -> (name: String, label: String)? {
        guard part.line.uppercased().hasPrefix("* LIST "),
              let flags = capture(#"^\* LIST \(([^)]*)\)"#, in: part.line) else { return nil }
        let set = Set(flags.lowercased().split(separator: " ").map(String.init))
        let label: String
        if set.contains("\\all") { label = "全部邮件" }
        else if set.contains("\\junk") { label = "垃圾邮件" }
        else if set.contains("\\trash") { label = "已删除邮件" }
        else { return nil }
        if let literal = part.literal, let name = String(data: literal, encoding: .utf8) { return (name, label) }
        guard let token = capture(#"^\* LIST \([^)]*\) (?:NIL|"(?:[^"\\]|\\.)*") (.+)$"#, in: part.line) else { return nil }
        let name: String
        if token.hasPrefix("\""), token.hasSuffix("\"") {
            name = String(token.dropFirst().dropLast()).replacingOccurrences(of: #"\(.)"#, with: "$1", options: .regularExpression)
        } else { name = token }
        return (name, label)
    }
    static func searchIDs(_ parts: [IMAPPart]) -> [String] {
        parts.filter { $0.line.uppercased().hasPrefix("* SEARCH") }.flatMap {
            $0.line.split(separator: " ").dropFirst(2).map(String.init).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
    }
    static func hit(_ part: IMAPPart, since date: Date) -> MailHit? {
        guard let bytes = part.literal,
              let raw = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
              let id = capture(#"X-GM-MSGID (\d+)"#, in: part.line),
              let received = capture(#"INTERNALDATE "([^"]+)""#, in: part.line).flatMap(MailRules.internalDate),
              received >= date else { return nil }
        let headers = MailRules.headers(raw)
        guard let from = headers["from"], MailRules.isAnthropicSender(from) else { return nil }
        return MailHit(id: id, subject: MailRules.decodeHeader(headers["subject"] ?? "（无主题）"),
                       sender: MailRules.senderAddress(from) ?? from, receivedAt: received)
    }
    static func fetchRecords(_ parts: [IMAPPart]) -> [IMAPPart] {
        var records: [IMAPPart] = []
        for part in parts {
            if capture(#"^\* (\d+) FETCH \("#, in: part.line) != nil { records.append(part) }
            else if !records.isEmpty && !part.line.hasPrefix("*") {
                records[records.count - 1].line += " " + part.line
                if let literal = part.literal { records[records.count - 1].literal = literal }
            }
        }
        return records
    }
}

protocol IMAPCommanding: Sendable {
    func connect() async throws
    func command(_ command: String, login: Bool) async throws -> [IMAPPart]
}
extension IMAPCommanding {
    func command(_ command: String) async throws -> [IMAPPart] { try await self.command(command, login: false) }
}

private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}

actor IMAPSession: IMAPCommanding {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.qishi.imap")
    private var buffer = Data()
    private var number = 0
    private var consumed = 0

    init() {
        // Network.framework validates Gmail's TLS certificate and hostname.
        connection = NWConnection(host: "imap.gmail.com", port: 993, using: .tls)
    }
    func cancel() { connection.cancel() }
    func connect() async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success(()))
                case .failed: once.finish(.failure(MailError.message("无法连接 Gmail。请检查网络，以及是否允许连接 imap.gmail.com:993。")))
                case .cancelled: once.finish(.failure(MailError.message("连接已取消或超时，请稍后重试。")))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        let greeting = try await line()
        guard greeting.uppercased().hasPrefix("* OK") else { throw MailError.message("Gmail 未返回有效的 IMAP 欢迎信息。") }
    }
    private func receive() async throws {
        try Task.checkCancellation()
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if error != nil { continuation.resume(throwing: MailError.message("Gmail 连接中断或超时；上次结果已保留。")) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(throwing: MailError.message("Gmail 提前关闭了连接，请重试。")) }
                else { continuation.resume(throwing: MailError.message("未收到 Gmail 响应，请重试。")) }
            }
        }
        consumed += bytes.count
        guard consumed < 8_000_000 else { throw MailError.message("匹配结果过多，已停止本轮检查；请确认注册时间。") }
        buffer.append(bytes)
    }
    private func line() async throws -> String {
        let separator = Data([13, 10])
        while buffer.range(of: separator) == nil { try await receive() }
        let range = buffer.range(of: separator)!
        let bytes = buffer[..<range.lowerBound]
        let value = String(decoding: bytes, as: UTF8.self)
        buffer.removeSubrange(..<range.upperBound)
        return value
    }
    private func literal(_ count: Int) async throws -> Data {
        guard count <= 131072 else { throw MailError.message("邮件头超过大小限制，无法完整检查。") }
        while buffer.count < count { try await receive() }
        let data = Data(buffer.prefix(count)); buffer.removeFirst(count); return data
    }
    func command(_ command: String, login: Bool = false) async throws -> [IMAPPart] {
        try Task.checkCancellation()
        number += 1
        let tag = String(format: "Q%04d", number)
        let bytes = Data("\(tag) \(command)\r\n".utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: MailError.message("无法发送 Gmail 检查请求。")) }
                else { continuation.resume(returning: ()) }
            })
        }
        var parts: [IMAPPart] = []
        while true {
            let text = try await line()
            if text.hasPrefix(tag + " ") {
                guard text.uppercased().hasPrefix(tag + " OK") else {
                    throw MailError.message(login ? "Gmail 登录失败。请使用开启两步验证后生成的 16 位应用专用密码，并检查邮箱地址。" : "Gmail 未完成检查。请确认 IMAP 可用，且“全部邮件”、垃圾邮件和已删除邮件允许通过 IMAP 访问。")
                }
                return parts
            }
            if text.uppercased().hasPrefix("* BYE") { throw MailError.message("Gmail 已断开连接，请稍后重试。") }
            var part = IMAPPart(line: text)
            if let rawCount = IMAPParser.capture(#"\{(\d+)\+?\}$"#, in: text), let count = Int(rawCount) {
                part.literal = try await literal(count)
            }
            parts.append(part)
        }
    }
}

struct MailCheckResult: Sendable { var hits: [MailHit]; var folders: [String] }

enum GmailChecker {
    static func check(settings: MonitorSettings, password: String) async throws -> MailCheckResult {
        let session = IMAPSession()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(90)); await session.cancel() } catch { }
        }
        defer { timeout.cancel(); Task { await session.cancel() } }
        return try await withTaskCancellationHandler {
            try await perform(settings: settings, password: password, session: session)
        } onCancel: { Task { await session.cancel() } }
    }
    static func perform(settings: MonitorSettings, password: String, session: any IMAPCommanding) async throws -> MailCheckResult {
            guard let registered = settings.registeredAt else { throw MailError.message("请先设置账号注册时间。") }
            try await session.connect()
            _ = try await session.command("LOGIN \(IMAPParser.quoted(settings.normalizedEmail)) \(IMAPParser.quoted(password))", login: true)
            let capabilities = try await session.command("CAPABILITY")
            guard capabilities.contains(where: { $0.line.uppercased().contains("X-GM-EXT-1") }) else {
                throw MailError.message("当前邮箱未提供 Gmail 搜索能力。请连接 Google 托管的 Gmail 邮箱。")
            }
            let folders = try await session.command("LIST \"\" \"*\"").compactMap(IMAPParser.mailbox)
            guard folders.contains(where: { $0.label == "全部邮件" }) else {
                throw MailError.message("Gmail 未向 IMAP 显示“全部邮件”。请在 Gmail 设置的“标签”中启用“在 IMAP 中显示”。")
            }
            // Require full coverage; an inaccessible folder must never turn into a clean result.
            guard Set(folders.map(\.label)).count == 3 else {
                throw MailError.message("无法完整检查全部邮件、垃圾邮件及已删除邮件。请在 Gmail 的“标签”设置中启用它们的 IMAP 显示。")
            }
            var hits: [String: MailHit] = [:]
            for folder in folders {
                _ = try await session.command("EXAMINE \(IMAPParser.quoted(folder.name))")
                let response = try await session.command("UID SEARCH X-GM-RAW \(IMAPParser.quoted(MailRules.query(since: registered)))")
                let ids = IMAPParser.searchIDs(response)
                guard ids.count <= 1000 else { throw MailError.message("匹配邮件超过 1000 封，请检查注册时间；未将本轮标记为成功。") }
                for start in stride(from: 0, to: ids.count, by: 40) {
                    let batch = ids[start..<min(start + 40, ids.count)].joined(separator: ",")
                    let messages = try await session.command("UID FETCH \(batch) (UID X-GM-MSGID INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])")
                    let records = IMAPParser.fetchRecords(messages)
                    guard records.count == min(40, ids.count - start), records.allSatisfy({ part in
                        part.literal != nil && IMAPParser.capture(#"X-GM-MSGID (\d+)"#, in: part.line) != nil &&
                        IMAPParser.capture(#"INTERNALDATE "([^"]+)""#, in: part.line).flatMap(MailRules.internalDate) != nil
                    }) else { throw MailError.message("部分邮件头无法完整读取，未将本轮标记为成功，请重试。") }
                    for part in records {
                        if let hit = IMAPParser.hit(part, since: registered) { hits[hit.id] = hit }
                    }
                }
            }
            return MailCheckResult(hits: hits.values.sorted { $0.receivedAt > $1.receivedAt }, folders: folders.map(\.label))
    }
}
