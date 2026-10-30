import SwiftUI
import AppKit
import ImageIO

struct OriginalClawdAnimation: NSViewRepresentable {
    var name: String
    var animate: Bool
    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.wantsLayer = true
        view.layer?.magnificationFilter = .nearest
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 112, height: proposal.height ?? 112)
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        let key = name + (animate ? "-animated" : "-still")
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Clawd/\(name).gif") else { return }
        if animate {
            view.image = NSImage(contentsOf: url)
            view.animates = true
        } else {
            view.animates = false
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let first = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                view.image = NSImage(cgImage: first, size: .zero)
            }
        }
        view.setAccessibilityLabel(L("Clawd 原版动画", "Original Clawd animation"))
    }
}
/// Durations of the bundled Clawd GIFs, read once from their frame delays.
@MainActor enum ClawdAnimations {
    /// Upstream Clawd on Desk loops plus the Qishi originals drawn by
    /// Scripts/make-clawd-animations.py. Alert loops (error, notification) are
    /// left out so a random pick never looks like a real problem.
    static let pool = ["idle", "idle-reading", "typing", "building", "thinking", "juggling", "sweeping",
                       "headphones-groove", "happy", "sleeping",
                       "qishi-hop", "qishi-wave", "qishi-look", "qishi-crabwalk", "qishi-heart", "qishi-hum"]
    private static var durations: [String: Double] = [:]
    static func duration(_ name: String) -> Double {
        if let cached = durations[name] { return cached }
        var total = 0.0
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Clawd/\(name).gif"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            for index in 0..<CGImageSourceGetCount(source) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
        }
        durations[name] = total
        return total
    }
}
/// The workbench's only character: Clawd's pixel animations in random order.
/// Each pick plays whole loops (at least three seconds); a click skips ahead.
struct ClawdStage: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ViewState private var current = ClawdAnimations.pool.randomElement() ?? "idle"
    @ViewState private var turn = 0
    var size: CGFloat = 260
    /// Shown instead of the random loop while set (the WebRTC leak alert).
    var override: String?
    var body: some View {
        Button(action: advance) {
            OriginalClawdAnimation(name: override ?? current, animate: !reduceMotion)
                .frame(width: size, height: size)
        }.buttonStyle(.plain)
            .disabled(override != nil)
            .help(override == nil ? L("点一下换个动作", "Click for another animation") : L("检测到 WebRTC 泄漏", "WebRTC leak detected"))
            .accessibilityLabel(L("Clawd 像素动画，点按换一个", "Clawd pixel animation; press for another"))
            .task(id: "\(turn)-\(override ?? "")") {
                guard !reduceMotion, override == nil else { return }
                let loop = max(0.5, ClawdAnimations.duration(current))
                let seconds = loop * max(1, (3 / loop).rounded(.up))
                do { try await Task.sleep(for: .seconds(seconds)); advance() } catch {}
            }
    }
    private func advance() {
        current = ClawdAnimations.pool.filter { $0 != current }.randomElement() ?? "idle"
        turn += 1
    }
}
/// Layers of the Claude starburst, split by Scripts/make-claude-logo.py.
@MainActor enum ClaudeLogoArt {
    struct Layout: Decodable {
        struct Spoke: Decodable { let file: String; let angle: Double }
        let size: [Double]; let center: [Double]; let core: String; let coreRadius: Double; let spokes: [Spoke]
    }
    static let folder = Bundle.main.resourceURL?.appendingPathComponent("ClaudeLogo")
    static let layout: Layout? = folder.flatMap { try? JSONDecoder().decode(Layout.self, from: Data(contentsOf: $0.appendingPathComponent("layout.json"))) }
    private static var images: [String: NSImage] = [:]
    static func image(_ file: String) -> NSImage? {
        if let cached = images[file] { return cached }
        guard let url = folder?.appendingPathComponent(file), let image = NSImage(contentsOf: url) else { return nil }
        images[file] = image
        return image
    }
}
/// The workbench mark. The core (hub and the roots of all rays, where they
/// join) never moves; each ray's outer part slowly lengthens and shortens from
/// the point where it leaves the core, so the star stays one piece and its
/// widths never change. Rays move on their own slow rhythms, a little quicker
/// while Claude works, and hold still with Reduce Motion.
struct ClaudeLogoView: View {
    var busy: Bool
    var size: CGFloat = 200
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        Group {
            if let layout = ClaudeLogoArt.layout {
                let width = layout.size[0], height = layout.size[1]
                let center = UnitPoint(x: layout.center[0] / width, y: layout.center[1] / height)
                // After rotating a ray onto the +x axis, it leaves the core here.
                let root = UnitPoint(x: (layout.center[0] + layout.coreRadius) / width, y: layout.center[1] / height)
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate * (busy ? 1.5 : 1)
                    ZStack {
                        ForEach(layout.spokes.indices, id: \.self) { index in
                            let angle = Angle.degrees(layout.spokes[index].angle)
                            layer(layout.spokes[index].file)
                                .rotationEffect(-angle, anchor: center)
                                .scaleEffect(x: reduceMotion ? 1 : stretch(index, time), y: 1, anchor: root)
                                .rotationEffect(angle, anchor: center)
                        }
                        layer(layout.core)
                    }
                }
            } else {
                Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(Color.qishiAccent)
            }
        }.frame(width: size, height: size)
            .accessibilityElement().accessibilityLabel("Claude")
    }
    /// A slow main wave (7–11 s) plus a slower one; golden-ratio phases keep
    /// neighbouring rays out of step, so no rotating pattern appears.
    private func stretch(_ index: Int, _ time: Double) -> CGFloat {
        let seed = (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        let period = 9 / (0.8 + seed * 0.45)
        let phase = seed * 2 * .pi
        let wave = 0.7 * sin(time * 2 * .pi / period + phase) + 0.3 * sin(time * 2 * .pi / (period * 1.9) + phase * 2.3)
        return CGFloat(1 + 0.11 * wave)
    }
    private func layer(_ file: String) -> some View {
        Group { if let image = ClaudeLogoArt.image(file) { Image(nsImage: image).resizable().scaledToFit() } }
    }
}
struct ClaudeWorkView: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var monitor: MonitorStore
    var body: some View {
        Group {
            PageScroll {
                if claude.preview {
                    Label(L("界面预览 · 示例数据", "Interface preview · sample data"), systemImage: "photo")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                // The mark stands on the page itself; only the status sits on glass.
                HStack(alignment: .center, spacing: 22) {
                    ClaudeLogoView(busy: claude.pose.busy || claude.busyCount > 0, size: 196)
                        .padding(.horizontal, 6)
                    NativeCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(claude.connected ? L("Claude Code 已接入", "Claude Code connected") : L("Claude Code 未接入", "Claude Code not connected"),
                                      systemImage: claude.connected ? "link" : "sparkle")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(claude.connected ? Color.qishiAccent : Color.secondary)
                                Text(LT(claude.pose.title)).font(.system(size: 28, weight: .semibold))
                                Text(claude.busyCount > 1 ? L("\(claude.busyCount) 个会话正在工作", "\(claude.busyCount) sessions working") : (claude.focus.map { LT($0.project) } ?? L("暂无活动会话", "No active session")))
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                                if claude.connected {
                                    HStack(spacing: 14) {
                                        Label(L("\(claude.live.count) 个会话", "\(claude.live.count) sessions"), systemImage: "bubble.left.and.bubble.right")
                                        Label(L("\(claude.requests.count) 待确认", "\(claude.requests.count) pending"), systemImage: "hand.raised")
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Spacer()
                                    if !claude.connected {
                                        Button(L("接入 Claude Code", "Connect Claude Code")) { claude.connect(true) }.buttonStyle(.glassProminent)
                                    }
                                    Button(claude.preferences.anyPetShown ? L("收起桌面伙伴", "Hide companions") : L("显示桌面伙伴", "Show companions")) {
                                        let show = !claude.preferences.anyPetShown
                                        claude.preferences.showClaude = show; claude.preferences.showClawd = show; claude.save()
                                    }.buttonStyle(.glass)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(claude.requests) { request in ClaudeApprovalCard(claude: claude, request: request) }
                NativeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            CardTitle(title: L("用量与额度", "Usage & limits"), symbol: "chart.bar")
                            Spacer()
                            if let s = claude.focus { Text(s.model.isEmpty ? LT(s.project) : s.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        if let session = claude.focus, !session.quota.isEmpty {
                            ForEach(session.quota) { quota in quotaRow(quota, session: session) }
                            if let used = session.contextUsed {
                                HStack { Text(L("上下文已用", "Context used")); Spacer(); Text("\(Int(used))%").monospacedDigit() }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(L("等待 Claude Code 上报额度", "Waiting for Claude Code to report usage")).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                TokenActivityCard(store: claude.tokens)
                NativeCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: L("会话", "Sessions"), symbol: "square.stack.3d.up")
                        if shownSessions.isEmpty {
                            Text(L("暂无会话", "No sessions yet")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(shownSessions) { session in sessionRow(session) }
                    }
                }
                NativeCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            CardTitle(title: L("账户守护", "Account"), symbol: "hourglass")
                            Text(monitor.settings.registeredAt.map { L("注册至今 \(Elapsed(since: $0, now: claude.now).days) 天", "\(Elapsed(since: $0, now: claude.now).days) days since registration") } ?? L("尚未设置注册时间", "Registration time not set"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(); StatusPill(snapshot: monitor.snapshot)
                        Button(L("查看", "View")) { monitor.selectedPage = 0 }.buttonStyle(.glass)
                    }
                }
            }
        }.navigationTitle(L("Claude 工作台", "Claude Workbench"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { claude.openClaude() } label: { Label(L("打开 Claude", "Open Claude"), systemImage: "arrow.up.forward.app") }
                        .help(L("打开 Claude", "Open Claude"))
                }
            }
    }
    /// The five most recent sessions that actually used a tool; idle shells are hidden.
    private var shownSessions: [ClaudeSession] { Array(claude.sessions.filter { $0.toolCount > 0 }.prefix(5)) }
    private func sessionRow(_ session: ClaudeSession) -> some View {
        let selected = claude.focus?.id == session.id
        return HStack(spacing: 12) {
            Image(systemName: session.pose.symbol).font(.system(size: 16)).foregroundStyle(tone(session.pose)).frame(width: 28)
            Button { claude.selectedID = session.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT(session.project)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(sessionDetail(session)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L("选择此会话的额度", "Show this session's usage"))
            VStack(alignment: .trailing, spacing: 4) {
                Text(session.closed ? L("已结束", "Ended") : session.stale(at: claude.now.timeIntervalSince1970) ? L("等待更新", "Awaiting update") : LT(session.pose.title))
                    .foregroundStyle(tone(session.pose)).font(.system(size: 12, weight: .medium))
                Text(Date(timeIntervalSince1970: session.updated), style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { claude.openProject(session) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                .help(L("打开项目文件夹", "Open project folder")).accessibilityLabel(L("打开 \(session.project) 文件夹", "Open \(session.project) folder"))
        }.padding(12)
            .background(selected ? Color.qishiAccent.opacity(0.10) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay { if selected { RoundedRectangle(cornerRadius: 12).stroke(Color.qishiAccent.opacity(0.35), lineWidth: 1) } }
    }
    private func sessionDetail(_ session: ClaudeSession) -> String {
        let model = session.model.isEmpty ? "Claude" : session.model
        let agents = session.agents.isEmpty ? "" : L(" · \(session.agents.count) 个子任务", " · \(session.agents.count) subagents")
        return model + L(" · \(session.toolCount) 次工具调用", " · \(session.toolCount) tool calls") + agents
    }
    private func tone(_ pose: ClaudePose) -> Color { pose == .error ? .red : pose == .happy ? .green : pose == .asking ? .orange : pose.busy ? .qishiAccent : .secondary }
    private func quotaRow(_ q: ClaudeQuota, session: ClaudeSession) -> some View {
        let stale = session.quotaUpdated.map { claude.now.timeIntervalSince1970 - $0 > 900 } ?? true
        let resetPassed = q.resetsAt.map { $0 <= claude.now.timeIntervalSince1970 } ?? false
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(LT(q.title)).font(.system(size: 13, weight: .medium))
                Spacer(); Text(L("已用 \(Int(q.used))% · 剩余 \(Int(100 - q.used))%", "\(Int(q.used))% used · \(Int(100 - q.used))% left")).font(.system(size: 12)).monospacedDigit()
            }
            ProgressView(value: q.used, total: 100).tint(q.used >= 90 ? .red : q.used >= 70 ? .orange : .qishiAccent)
            HStack {
                if let reset = q.resetsAt {
                    Text(resetPassed ? L("已到重置时间，等待新数据", "Reset time reached; waiting for new data") : L("重置：", "Resets: ") + Date(timeIntervalSince1970: reset).qishiFormatted())
                }
                Spacer()
                if let ts = session.quotaUpdated {
                    Text((stale ? L("旧数据 · ", "Stale · ") : "") + Date(timeIntervalSince1970: ts).qishiFormatted(date: .omitted))
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.opacity(stale || resetPassed ? 0.65 : 1)
    }
}
/// A year of token use as a calendar grid: columns are weeks, rows weekdays.
/// Cells take four validated steps of the accent hue by quartile of the active
/// values; daily, weekly and cumulative views share the grid. Hovering a cell
/// reads out its date and value, and the details table lists the last 14 days.
struct TokenActivityCard: View {
    enum Mode: CaseIterable { case daily, weekly, total }
    @ObservedObject var store: TokenUsageStore
    @ViewState private var mode: Mode
    @ViewState private var hovered: Date?
    @Environment(\.colorScheme) private var scheme
    private let gap: CGFloat = 3
    init(store: TokenUsageStore, mode: Mode = .daily) {
        self.store = store
        _mode = ViewState(initialValue: mode)
    }

    private struct Week: Identifiable { let id: Date; let days: [Date?] }   // nil: after today

    var body: some View {
        let calendar = Calendar.current
        let byDay = Dictionary(store.daily.map { ($0.day, $0.counts) }, uniquingKeysWith: { a, _ in a })
        let weeks = Self.weeks(calendar: calendar)
        let values = self.values(weeks, byDay)
        let levels = self.levels(weeks, values)
        let yearTotal = store.daily.reduce(0) { $0 + $1.counts.total }
        let thisWeek = weeks.last?.days.compactMap { $0 }.reduce(0) { $0 + (byDay[$1]?.total ?? 0) } ?? 0
        NativeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    CardTitle(title: L("Token 活动", "Token activity"), symbol: "square.grid.3x3.fill")
                    Spacer()
                    HStack(spacing: 14) {
                        ForEach(Mode.allCases, id: \.self) { option in
                            Button(title(option)) { mode = option }.buttonStyle(.plain)
                                .font(.system(size: 13, weight: mode == option ? .semibold : .regular))
                                .foregroundStyle(mode == option ? Color.primary : Color.secondary)
                                .accessibilityAddTraits(mode == option ? [.isSelected] : [])
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    tile(L("今天", "Today"), byDay[calendar.startOfDay(for: Date())]?.total ?? 0)
                    tile(L("本周", "This week"), thisWeek)
                    tile(L("近一年合计", "Past year"), yearTotal)
                    Spacer()
                }
                if yearTotal == 0 {
                    Text(L("近一年没有 Claude Code 用量记录。", "No Claude Code usage in the past year."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    grid(weeks, levels: levels, values: values)
                }
                HStack(spacing: 8) {
                    Text(readout(values, byDay)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    legend
                }
                DisclosureGroup(L("明细（近 14 天）", "Details (last 14 days)")) { table(Array(store.daily.suffix(14))) }
                    .font(.system(size: 12))
            }
        }
    }

    /// 53 week columns ending with the current week, in the locale's week order.
    private static func weeks(calendar: Calendar) -> [Week] {
        let today = calendar.startOfDay(for: Date())
        guard let current = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        return (0..<53).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current) else { return nil }
            let days = (0..<7).map { offset -> Date? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
                return day > today ? nil : day
            }
            return Week(id: start, days: days)
        }
    }
    /// The value each cell shows in the current view.
    private func values(_ weeks: [Week], _ byDay: [Date: TokenCounts]) -> [Date: Int] {
        var result: [Date: Int] = [:], running = 0
        for week in weeks {
            let days = week.days.compactMap { $0 }
            let weekTotal = days.reduce(0) { $0 + (byDay[$1]?.total ?? 0) }
            for day in days {
                let own = byDay[day]?.total ?? 0
                running += own
                switch mode {
                case .daily: result[day] = own
                case .weekly: result[day] = weekTotal
                case .total: result[day] = running
                }
            }
        }
        return result
    }
    /// Level 0 for no use, then 1...4 by quartile of the active values (per week in the weekly view).
    private func levels(_ weeks: [Week], _ values: [Date: Int]) -> [Date: Int] {
        let samples = mode == .weekly ? weeks.compactMap { $0.days.compactMap { $0 }.first.flatMap { values[$0] } }.filter { $0 > 0 }
                                      : values.values.filter { $0 > 0 }
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return values.mapValues { _ in 0 } }
        let cuts = [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
        return values.mapValues { value in value <= 0 ? 0 : 1 + cuts.filter { value > $0 }.count }
    }
    /// Validated ordinal steps: light mode darkens with use, dark mode brightens.
    private var steps: [Color] {
        let hex: [UInt32] = scheme == .dark ? [0x8C4A35, 0xAF5D42, 0xD27050, 0xE09D88] : [0xE39C85, 0xD97757, 0xB16147, 0x8B4C38]
        return hex.map { Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) }
    }
    private func fill(_ level: Int) -> Color { level == 0 ? Color.primary.opacity(0.07) : steps[min(level, 4) - 1] }

    private static let cell: CGFloat = 11
    /// Fixed-size cells, as many recent weeks as the card's width holds (all 53 at
    /// the default window width); month labels share the same column positions.
    private func grid(_ allWeeks: [Week], levels: [Date: Int], values: [Date: Int]) -> some View {
        let cell = Self.cell, pitch = Self.cell + gap
        return GeometryReader { geometry in
            let fit = max(1, min(allWeeks.count, Int((geometry.size.width + gap) / pitch)))
            let weeks = Array(allWeeks.suffix(fit))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(weeks) { week in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                if let day = week.days[row] {
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(fill(levels[day] ?? 0))
                                        .overlay { if hovered == day { RoundedRectangle(cornerRadius: 2.5).stroke(Color.primary.opacity(0.55), lineWidth: 1) } }
                                        .frame(width: cell, height: cell)
                                        .contentShape(Rectangle())
                                        .onHover { inside in if inside { hovered = day } else if hovered == day { hovered = nil } }
                                        .accessibilityElement()
                                        .accessibilityLabel(day.qishiFormatted(date: .abbreviated, time: .omitted))
                                        .accessibilityValue(L("\(values[day] ?? 0) 个 token", "\(values[day] ?? 0) tokens"))
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(weeks.enumerated()), id: \.element.id) { index, _ in
                        if let label = monthLabel(weeks, index) {
                            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                                .offset(x: CGFloat(index) * pitch)
                        }
                    }
                }.frame(height: 14, alignment: .topLeading)
            }
        }
        .frame(height: 7 * cell + 6 * gap + 6 + 14)
        .onHover { inside in if !inside { hovered = nil } }
    }
    /// A month's name under the first week that starts in it (skipped if the next is too close).
    private func monthLabel(_ weeks: [Week], _ index: Int) -> String? {
        let calendar = Calendar.current
        func month(_ i: Int) -> Int? { weeks[i].days.compactMap { $0 }.first.map { calendar.component(.month, from: $0) } }
        guard let current = month(index) else { return nil }
        if index > 0, month(index - 1) == current { return nil }
        if index == 0, weeks.count > 2, month(1) != current || month(2) != current { return nil }
        return weeks[index].days.compactMap { $0 }.first?.formatted(Date.FormatStyle(locale: Loc.locale).month(.abbreviated))
    }
    private var legend: some View {
        HStack(spacing: 4) {
            Text(L("少", "Less")).font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in RoundedRectangle(cornerRadius: 2).fill(fill(level)).frame(width: 10, height: 10) }
            Text(L("多", "More")).font(.system(size: 10)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel(L("颜色越深用量越多", "Darker means more tokens"))
    }
    private func readout(_ values: [Date: Int], _ byDay: [Date: TokenCounts]) -> String {
        guard let day = hovered else {
            return L("来自本机 Claude Code 会话记录", "From local Claude Code transcripts")
                + (store.updatedAt.map { L(" · 更新于 ", " · updated ") + $0.qishiFormatted(date: .omitted) } ?? "")
        }
        let date = day.qishiFormatted(date: .abbreviated, time: .omitted), value = compact(values[day] ?? 0)
        switch mode {
        case .daily: return "\(date) · \(value) tokens"
        case .weekly:
            let start = Calendar.current.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            return L("\(start.qishiFormatted(date: .abbreviated, time: .omitted)) 起一周 · \(value) tokens", "Week of \(start.qishiFormatted(date: .abbreviated, time: .omitted)) · \(value) tokens")
        case .total: return L("截至 \(date) · 累计 \(value) tokens", "Through \(date) · \(value) tokens in total")
        }
    }
    private func title(_ mode: Mode) -> String {
        switch mode { case .daily: return L("每天", "Daily"); case .weekly: return L("每周", "Weekly"); case .total: return L("累计总量", "Cumulative") }
    }
    private func table(_ days: [DailyTokens]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text(L("日期", "Date")).gridColumnAlignment(.leading)
                Text(L("合计", "Total")); Text(L("输入", "Input")); Text(L("输出", "Output")); Text(L("缓存写入", "Cache write")); Text(L("缓存读取", "Cache read"))
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(days.reversed()) { day in
                GridRow {
                    Text(day.day.qishiFormatted(date: .abbreviated, time: .omitted))
                    Text(compact(day.counts.total)).fontWeight(.medium)
                    Text(compact(day.counts.input)); Text(compact(day.counts.output))
                    Text(compact(day.counts.cacheWrite)); Text(compact(day.counts.cacheRead))
                }.font(.system(size: 11)).monospacedDigit()
            }
        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tile(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(compact(value)).font(.system(size: 22, weight: .semibold))
        }
    }
    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(Loc.locale))
    }
}
struct ClaudeApprovalCard: View {
    @ObservedObject var claude: ClaudeStore
    var request: ClaudeRequest
    var body: some View {
        NativeCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Claude 请求使用 \(request.tool)", "Claude wants to use \(request.tool)"), systemImage: "hand.raised.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
                Text(LT(request.project)).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView([.horizontal, .vertical]) {
                    Text(request.input).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10)
                }.frame(height: 110).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text(L("只决定本次操作 · \(max(0, Int(request.expires - claude.now.timeIntervalSince1970))) 秒后交回 Claude",
                       "Applies to this action only · returns to Claude in \(max(0, Int(request.expires - claude.now.timeIntervalSince1970))) s"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L("回 Claude 处理", "Handle in Claude")) { claude.decide(request, choice: "native"); claude.openClaude() }.buttonStyle(.glass)
                    Button(L("拒绝", "Deny"), role: .destructive) { claude.decide(request, choice: "deny") }.buttonStyle(.glass)
                    Button(L("允许一次", "Allow once")) { claude.decide(request, choice: "allow") }.buttonStyle(.glassProminent)
                }
            }
        }
    }
}
struct ClaudeApprovalQueue: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var prefs = AppPreferences.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(claude.requests) { request in ClaudeApprovalCard(claude: claude, request: request) }
            }.padding(12)
        }.background(Color.qishiPage)
            .id(prefs.language)
            .tint(.qishiAccent)
    }
}
struct ClaudeSettingsView: View {
    @ObservedObject var claude: ClaudeStore
    var body: some View {
        Group {
            PageScroll {
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: "Claude Code", symbol: "link")
                        HStack(spacing: 10) {
                            Label(claude.connected ? L("已接入", "Connected") : L("尚未接入", "Not connected"),
                                  systemImage: claude.connected ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 13)).foregroundStyle(claude.connected ? Color.green : Color.secondary)
                            Spacer()
                            if claude.connected { Button(L("撤销接入", "Disconnect")) { claude.connect(false) }.buttonStyle(.glass) }
                            Button(claude.connected ? L("修复接入", "Repair") : L("接入 Claude Code", "Connect Claude Code")) { claude.connect(true) }.buttonStyle(.glassProminent)
                        }
                        HStack {
                            Spacer()
                            Button(L("查看接入备份", "Show integration backups"), systemImage: "folder") {
                                NSWorkspace.shared.open(ClaudeFiles.root.appendingPathComponent("Backups"))
                            }.buttonStyle(.accentLink).font(.system(size: 12))
                        }
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: L("桌面伙伴", "Desktop companions"), symbol: "sparkles")
                        toggle(L("显示 Claude 娘", "Show Claude-chan"), \.showClaude)
                        toggle(L("显示 Clawd", "Show Clawd"), \.showClawd)
                        toggle(L("浮在其他窗口上方", "Float above other windows"), \.alwaysOnTop)
                        HStack(spacing: 12) {
                            Text(L("大小", "Size")).font(.system(size: 13))
                            Slider(value: Binding(get: { claude.preferences.petScale }, set: { claude.preferences.petScale = $0; claude.save() }), in: 0.75...1.25)
                            Text("\(Int(claude.preferences.petScale * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: L("提醒与授权", "Alerts & approvals"), symbol: "bell")
                        toggle(L("在栖时确认单次工具授权", "Approve single tool requests in Qishi"), \.approvals)
                            .help(L("90 秒未处理会交回 Claude；提问和计划确认仍在 Claude 内完成。", "Unanswered requests return to Claude after 90 s; questions and plan approvals stay in Claude."))
                        SettingToggle(title: L("任务完成、出错和等待时通知", "Notify when done, on errors and when waiting"),
                                      isOn: Binding(get: { claude.preferences.notifications }, set: { claude.setNotifications($0) }))
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 8) {
                        DisclosureGroup {
                            Text(L("Claude 娘：CrossPet / lokicorvus · CC BY-NC-SA 4.0。Clawd：Clawd on Desk，素材权利归原作者。仅供个人非商业使用，非 Anthropic 官方应用。",
                                   "Claude-chan: CrossPet / lokicorvus · CC BY-NC-SA 4.0. Clawd: Clawd on Desk; artwork rights belong to the original authors. Personal, non-commercial use only. Not an official Anthropic app."))
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                                .fixedSize(horizontal: false, vertical: true)
                        } label: {
                            CardTitle(title: L("来源与许可", "Credits & licenses"), symbol: "info.circle")
                        }
                        HStack(spacing: 16) {
                            Link("Clawd on Desk", destination: URL(string: "https://github.com/rullerzhou-afk/clawd-on-desk")!)
                            Link("CrossPet", destination: URL(string: "https://github.com/lokicorvus/crosspet")!)
                        }.font(.system(size: 12)).foregroundStyle(Color.qishiAccent)
                    }
                }
            }
        }.navigationTitle(L("桌宠与接入", "Companions & Integration"))
    }
    private func toggle(_ title: String, _ key: WritableKeyPath<ClaudePreferences, Bool>) -> some View {
        SettingToggle(title: title, isOn: Binding(get: { claude.preferences[keyPath: key] }, set: { claude.preferences[keyPath: key] = $0; claude.save() }))
    }
}
