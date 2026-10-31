import Foundation

private var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAIL: \(message)") }
}
func rejects(_ operation: () throws -> Void, _ message: String) {
    do { try operation(); fatalError("FAIL: \(message)") } catch { checks += 1 }
}

actor FixtureSession: IMAPCommanding {
    var commands: [String] = []
    var missingFolder = false
    var failTrash = false
    var missingFetch = false
    init(missingFolder: Bool = false, failTrash: Bool = false, missingFetch: Bool = false) {
        self.missingFolder = missingFolder; self.failTrash = failTrash; self.missingFetch = missingFetch
    }
    func connect() async throws {}
    func command(_ command: String, login: Bool) async throws -> [IMAPPart] {
        commands.append(command)
        if command.hasPrefix("LOGIN") { return [] }
        if command == "CAPABILITY" { return [IMAPPart(line: "* CAPABILITY IMAP4rev1 X-GM-EXT-1")] }
        if command.hasPrefix("LIST") {
            var parts = [IMAPPart(line: #"* LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail""#),
                         IMAPPart(line: #"* LIST (\HasNoChildren \Junk) "/" "[Gmail]/Spam""#)]
            if !missingFolder { parts.append(IMAPPart(line: #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash""#)) }
            return parts
        }
        if command.hasPrefix("EXAMINE") {
            if failTrash && command.contains("Trash") { throw MailError.message("fixture mailbox failure") }
            return []
        }
        if command.hasPrefix("UID SEARCH") { return [IMAPPart(line: "* SEARCH 7 8")] }
        if command.hasPrefix("UID FETCH") {
            if missingFetch { return [] }
            return [
                IMAPPart(line: #"* 1 FETCH (UID 7 X-GM-MSGID 999 INTERNALDATE "28-Oct-2026 10:00:00 +0000" BODY[HEADER.FIELDS (FROM SUBJECT)] {100}"#,
                         literal: Data("From: Anthropic <support@anthropic.com>\r\nSubject: Your account has been suspended\r\n\r\n".utf8)),
                IMAPPart(line: ")"),
                IMAPPart(line: #"* 2 FETCH (UID 8 BODY[HEADER.FIELDS (FROM SUBJECT)] {100}"#,
                         literal: Data("From: Anthropic <fake@anthropic.com.evil.test>\r\nSubject: suspended\r\n\r\n".utf8)),
                IMAPPart(line: #"X-GM-MSGID 998 INTERNALDATE "28-Oct-2026 11:00:00 +0000")"#)
            ]
        }
        throw MailError.message("unexpected fixture command")
    }
}

@main struct CoreTests {
    static func main() async throws {
        let legacy = Data(#"{"email":"fixture@gmail.com","registeredAt":1234,"intervalMinutes":15,"monitoring":false,"desktopCard":true,"alwaysOnTop":true,"notify":true}"#.utf8)
        var migrated = try JSONDecoder().decode(MonitorSettings.self, from: legacy)
        expect(!migrated.hideDockIcon, "legacy settings default to visible Dock while open")
        expect(migrated.email == "fixture@gmail.com" && migrated.intervalMinutes == 15 && !migrated.monitoring && migrated.notify, "upgrade retains existing settings and ignores the removed desktop-card keys")
        migrated.hideDockIcon = true
        let reloaded = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(migrated))
        expect(reloaded == migrated, "Dock preference survives save and reload")
        // Daily token usage from Claude Code transcripts.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let transcript = Data(("""
        {"type":"user","timestamp":"2026-10-29T09:00:00.000Z","message":{"role":"user","content":"hi"}}
        {"type":"assistant","timestamp":"2026-10-29T09:00:01.000Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}
        {"type":"assistant","timestamp":"2026-10-29T09:00:02.000Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":40,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}
        not json but "output_tokens" appears
        {"type":"assistant","timestamp":"2026-10-30T23:59:59Z","requestId":"r2","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2}}}
        """).utf8)
        let usageEntries = TokenUsageParser.entries(fromJSONL: transcript)
        expect(usageEntries.count == 3, "only reply lines with a usage block are read")
        // The same reply copied into a resumed session counts once.
        let copied = TokenUsageParser.entries(fromJSONL: Data(#"{"timestamp":"2026-10-29T10:00:00.5Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":40}}}"#.utf8))
        let days = TokenUsageParser.daily(usageEntries + copied, days: 3, now: TokenUsageParser.date("2026-10-31T12:00:00Z")!, calendar: utc)
        expect(days.count == 3 && days.map(\.counts.total) == [1150, 3, 0], "replies are deduplicated, bucketed by day and zero-filled")
        expect(days[0].counts == TokenCounts(input: 10, output: 40, cacheWrite: 100, cacheRead: 1000), "a streamed reply keeps its largest counts")
        expect(TokenUsageParser.date("2026-10-30T23:59:59Z") != nil && TokenUsageParser.date("2026-10-30T23:59:59.123Z") != nil, "both timestamp forms parse")
        // Claude Desktop's own usage record: times, percentages and a hashed organization only.
        let record = Data(#"{"version":2,"samples":[{"t":1793277188297,"org":"org-a","u":{"fh":9,"sd":4}},{"t":1793278998465,"org":"org-a","u":{"fh":10,"sd":5,"xx":3}},{"t":"bad","u":{"fh":1}},{"t":1793280110525,"u":{"fh":true,"sd":-1}}]}"#.utf8)
        let desktopSamples = DesktopUsageParser.samples(from: record) ?? []
        expect(desktopSamples.count == 2 && desktopSamples[0].used == ["five_hour": 9, "seven_day": 4] && desktopSamples[1].used["xx"] == 3,
               "desktop record maps known keys, keeps unknown ones and skips malformed rows")
        expect(desktopSamples[0].time == 1_793_277_188 && desktopSamples[0].account.count == 12 && !desktopSamples[0].account.contains("org"),
               "desktop times are seconds and the organization id is stored only as a hash")
        expect(DesktopUsageParser.samples(from: Data("{}".utf8)) == nil && DesktopUsageParser.samples(from: Data("[1]".utf8)) == nil, "unknown formats are not usage")
        var desktopHistory = DesktopUsageHistory()
        expect(desktopHistory.merge(desktopSamples, now: 1_793_300_000) && !desktopHistory.merge(desktopSamples, now: 1_793_300_000), "readings merge once")
        var aged = desktopHistory
        expect(aged.merge([], now: 1_793_300_000 + 401 * 86_400) && aged.samples.isEmpty, "readings older than the keep window are dropped")
        let window = (id: "five_hour", used: 20.0, resetsAt: Optional(1_000.0 + 18_000))
        let laterDesktop = DesktopUsageSample(time: 2_000, account: "a", used: ["five_hour": 35, "seven_day": 50])
        let merged = LimitMerger.merge(code: [window, (id: "spend_limit", used: 5, resetsAt: nil)], codeUpdated: 1_000, desktop: laterDesktop)
        expect(merged.map(\.id) == ["five_hour", "seven_day", "spend_limit"] && merged[0].source == .claudeDesktop && merged[0].used == 35,
               "the fresher Desktop reading wins and limits keep their order")
        expect(merged[0].resetsAt == 19_000 && merged[1].resetsAt == nil && merged[2].source == .claudeCode, "a Desktop reading inside the same window keeps Claude Code's reset time")
        let afterReset = LimitMerger.merge(code: [window], codeUpdated: 1_000, desktop: DesktopUsageSample(time: 20_000, account: "a", used: ["five_hour": 2]))
        expect(afterReset[0].resetsAt == nil, "a Desktop reading after the reset drops the old reset time")
        let older = LimitMerger.merge(code: [window], codeUpdated: 3_000, desktop: laterDesktop)
        expect(older.first { $0.id == "five_hour" }?.source == .claudeCode, "an older Desktop reading never replaces Claude Code's")
        let start = Date(timeIntervalSince1970: 1_000_000)
        expect(Elapsed(since: start, now: start).days == 0, "zero age")
        expect(Elapsed(since: start, now: start.addingTimeInterval(90061)).clock == "01 : 01 : 01", "zero-padded clock formatting")
        let elapsed = Elapsed(since: start, now: start.addingTimeInterval(90061))
        expect(elapsed.days == 1 && elapsed.hours == 1 && elapsed.minutes == 1 && elapsed.seconds == 1, "day rollover")
        expect(Elapsed(since: start, now: start.addingTimeInterval(-1)).clock == "00 : 00 : 00", "future clamp")
        expect(Elapsed(since: start, now: start.addingTimeInterval(86400 * 400)).days == 400, "over one year")
        expect(Elapsed(since: start, now: start.addingTimeInterval(23 * 3600)).days == 0, "elapsed hours independent of DST")
        expect(MonitorSettings.validEmail("x+claude@gmail.com"), "gmail alias")
        expect(!MonitorSettings.validEmail("x@gmail.com\r\nA1 LOGOUT"), "email injection rejected")
        expect(MailRules.isAnthropicSender("Anthropic <no-reply@anthropic.com>"), "real domain")
        expect(MailRules.isAnthropicSender("a@MAIL.ANTHROPIC.COM"), "subdomain and case")
        expect(!MailRules.isAnthropicSender("Anthropic <a@evil.test>"), "display name not trusted")
        expect(!MailRules.isAnthropicSender("a@anthropic.com.evil.test"), "suffix spoof")
        expect(!MailRules.isAnthropicSender("a@notanthropic.com"), "lookalike domain")
        expect(MailRules.headers("From: a@anthropic.com\r\nFrom: b@evil.test")["from"] == "invalid duplicate from", "duplicate From rejected")
        expect(MailRules.headers("Subject: hello\r\n world\r\n")["subject"] == "hello world", "folded headers")
        expect(MailRules.decodeHeader("=?UTF-8?B?c3VzcGVuZGVk?=") == "suspended", "base64 subject")
        expect(MailRules.decodeHeader("=?UTF-8?Q?Account_suspended?=") == "Account suspended", "Q subject")
        expect(MailRules.decodeHeader("=?UTF-8?Q?Account_?= =?UTF-8?Q?suspended?=") == "Account suspended", "adjacent encoded words")
        expect(MailRules.query(since: start).contains("after:999999"), "epoch boundary")
        expect(MailRules.internalDate("28-Oct-2026 10:00:00 +0000") != nil, "internal date parsing")
        expect(MailRules.gmailURL(email: "a+b@gmail.com").host == "mail.google.com", "Gmail URL fixed origin")
        let quoted = try IMAPParser.quoted("a\"b\\c")
        expect(quoted == "\"a\\\"b\\\\c\"", "IMAP escaping")
        rejects({ _ = try IMAPParser.quoted("hello\r\nLOGOUT") }, "IMAP CRLF rejected")
        let box = IMAPParser.mailbox(IMAPPart(line: #"* LIST (\HasNoChildren \All) "/" "[Gmail]/&YkBnCZCuTvY-""#))
        expect(box?.name == "[Gmail]/&YkBnCZCuTvY-", "modified UTF7 mailbox preserved")
        expect(box?.label == "全部邮件", "special-use flag")
        let literalBox = IMAPParser.mailbox(IMAPPart(line: #"* LIST (\Trash) "/" {5}"#, literal: Data("Trash".utf8)))
        expect(literalBox?.name == "Trash", "literal mailbox")
        expect(IMAPParser.searchIDs([IMAPPart(line: "* SEARCH")]).isEmpty, "empty search")
        var state = MonitorSnapshot()
        expect(state.status(at: start).title == "等待连接", "unconfigured is not green")
        state.email = "test@gmail.com"; state.registeredAt = start
        expect(state.status(at: start).title == "等待首次检查", "first check pending")
        state.lastChecked = start
        expect(state.status(at: start).title == "未发现匹配邮件", "clean result wording")
        expect(state.status(at: start.addingTimeInterval(901)).title == "结果待更新", "stale state")
        state.error = "offline"
        expect(state.status(at: start).title == "检查未完成", "failure overrides clean")
        state.monitoring = false
        expect(state.status(at: start).title == "检测已暂停", "paused state")
        let roundtrip = try JSONDecoder().decode(MonitorSnapshot.self, from: JSONEncoder().encode(state))
        expect(roundtrip.error == "offline" && roundtrip.registeredAt == start, "snapshot persistence")

        var settings = MonitorSettings()
        settings.email = "fixture@gmail.com"; settings.registeredAt = start
        let session = FixtureSession()
        let result = try await GmailChecker.perform(settings: settings, password: "test-password", session: session)
        expect(result.hits.count == 1 && result.hits[0].id == "999", "dedup folders and reject sender spoof")
        expect(result.folders.count == 3, "all archive spam trash coverage")
        let commands = await session.commands
        expect(commands.filter { $0.hasPrefix("EXAMINE") }.count == 3, "read-only mailbox selection")
        expect(commands.filter { $0.hasPrefix("UID FETCH") }.allSatisfy { $0.contains("BODY.PEEK[") }, "never marks read")
        expect(!commands.contains { $0.hasPrefix("STORE") || $0.hasPrefix("SELECT") || $0.hasPrefix("EXPUNGE") }, "no mutations")
        for broken in [FixtureSession(missingFolder: true), FixtureSession(failTrash: true), FixtureSession(missingFetch: true)] {
            do { _ = try await GmailChecker.perform(settings: settings, password: "test", session: broken); fatalError("incomplete coverage must fail") }
            catch { checks += 1 }
        }
        print("PASS: \(checks) checks (time, parser, state, read-only IMAP workflow, partial failure)")
    }
}
