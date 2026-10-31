import SwiftUI
import Charts

/// "Usage & limits": each limit from whichever source read it last — the
/// focused Claude Code session's status line or Claude Desktop's own record —
/// followed by Claude Desktop's monitor state and the readings kept so far.
struct UsageLimitsCard: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var desktop: DesktopUsageStore
    @ViewState private var hovered: Double?
    @ViewState private var historyOpen: Bool
    @Environment(\.colorScheme) private var scheme
    private static let staleAfter: Double = 900
    private static let charted = ["five_hour", "seven_day"]
    /// Interface previews open the history so the chart shows up in them.
    init(claude: ClaudeStore, desktop: DesktopUsageStore) {
        self.claude = claude
        self.desktop = desktop
        _historyOpen = ViewState(initialValue: desktop.preview)
    }

    var body: some View {
        let now = claude.now.timeIntervalSince1970, limits = claude.limits
        NativeCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    CardTitle(title: L("用量与额度", "Usage & limits"), symbol: "chart.bar")
                    Spacer()
                    if let s = claude.focus, s.quotaUpdated != nil { Text(s.model.isEmpty ? LT(s.project) : s.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                if limits.isEmpty {
                    Text(L("等待 Claude Code 上报或 Claude Desktop 记录额度", "Waiting for Claude Code or Claude Desktop to report usage")).font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    ForEach(limits) { limit in row(limit, now: now) }
                }
                if let used = claude.focus?.contextUsed {
                    HStack { Text(L("上下文已用", "Context used")); Spacer(); Text("\(Int(used))%").monospacedDigit() }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                desktopSection
            }
        }
    }

    private func title(_ id: String) -> String {
        switch id {
        case "five_hour": return LT("5 小时额度")
        case "seven_day": return LT("每周额度")
        case "spend_limit": return LT("支出限额")
        default: return id
        }
    }
    private func source(_ source: MergedLimit.Source) -> String { source == .claudeCode ? "Claude Code" : "Claude Desktop" }
    private func time(_ seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        return date.qishiFormatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated)
    }

    private func row(_ q: MergedLimit, now: Double) -> some View {
        let stale = now - q.updated > Self.staleAfter
        let resetPassed = q.resetsAt.map { $0 <= now } ?? false
        let used = min(max(q.used, 0), 100)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title(q.id)).font(.system(size: 13, weight: .medium))
                Spacer(); Text(L("已用 \(Int(used))% · 剩余 \(Int(100 - used))%", "\(Int(used))% used · \(Int(100 - used))% left")).font(.system(size: 12)).monospacedDigit()
            }
            ProgressView(value: used, total: 100).tint(used >= 90 ? .red : used >= 70 ? .orange : .qishiAccent)
            HStack {
                if let reset = q.resetsAt {
                    Text(resetPassed ? L("已到重置时间，等待新数据", "Reset time reached; waiting for new data") : L("重置：", "Resets: ") + Date(timeIntervalSince1970: reset).qishiFormatted())
                }
                Spacer()
                Text((stale ? L("旧数据 · ", "Stale · ") : "") + source(q.source) + " · " + time(q.updated))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.opacity(stale || resetPassed ? 0.65 : 1)
    }

    // MARK: Claude Desktop

    private var desktopSection: some View {
        let week = Date().timeIntervalSince1970 - 7 * 86_400
        let recent = desktop.history.recent(since: week).filter { sample in Self.charted.contains { sample.used[$0] != nil } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Claude Desktop", systemImage: "macwindow").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(desktop.unreadable
                 ? L("Claude Desktop 的用量记录暂时无法读取，将在其更新后重试。", "Claude Desktop's usage record can't be read right now; it is retried after the next change.")
                 : L("Claude Desktop 运行时静默读取它自己保存的用量记录，只保留时间与百分比。记录由 Claude 写入：启动时，以及近 24 小时内打开过其用量面板时才会更新。",
                     "While Claude Desktop runs, the usage record it keeps for itself is read silently; only times and percentages are kept. Claude updates it at launch, and while its usage panel was opened in the last 24 hours."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if recent.count >= 2 {
                DisclosureGroup(L("额度记录（近 7 天）", "Limit history (last 7 days)"), isExpanded: $historyOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        chart(recent)
                        HStack(spacing: 8) {
                            Text(readout(recent)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                            Spacer()
                            legend
                        }
                        table(Array(recent.suffix(10).reversed()))
                    }.padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
    }
    private var status: String {
        let state = desktop.running ? L("运行中 · 静默记录", "Running · recording silently") : L("未运行 · 暂停记录", "Not running · paused")
        let count = desktop.history.samples.count
        return count == 0 ? state : state + L(" · 已保存 \(count) 条", " · \(count) saved")
    }

    /// Validated pair (light and dark steps): the accent for the 5-hour limit, blue for the weekly one.
    private func color(_ id: String) -> Color {
        let hex: UInt32 = id == "five_hour" ? (scheme == .dark ? 0xCC6A4B : 0xD97757) : (scheme == .dark ? 0x3987E5 : 0x2A78D6)
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    private struct Point: Identifiable { let id: String; let series: String; let date: Date; let used: Double }

    private func chart(_ samples: [DesktopUsageSample]) -> some View {
        let points = Self.charted.flatMap { key in
            samples.compactMap { s in s.used[key].map { Point(id: "\(key):\(s.time)", series: key, date: Date(timeIntervalSince1970: s.time), used: min($0, 100)) } }
        }
        let focus = hovered.flatMap { time in samples.first { $0.time == time } }
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("Used", p.used), series: .value("Limit", p.series))
                    .foregroundStyle(color(p.series)).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Time", p.date), y: .value("Used", p.used))
                    .foregroundStyle(color(p.series)).symbolSize(focus?.time == p.date.timeIntervalSince1970 ? 64 : 28)
            }
            if let focus {
                RuleMark(x: .value("Time", Date(timeIntervalSince1970: focus.time))).foregroundStyle(Color.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 9)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false).font(.system(size: 9))
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let frame = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geometry[frame].origin.x) else { hovered = nil; return }
                        let time = date.timeIntervalSince1970
                        hovered = samples.min { abs($0.time - time) < abs($1.time - time) }?.time
                    }
            }
        }
        .frame(height: 120)
        .accessibilityLabel(L("Claude Desktop 近 7 天额度记录图", "Claude Desktop limit readings, last 7 days"))
    }
    private func readout(_ samples: [DesktopUsageSample]) -> String {
        guard let sample = hovered.flatMap({ time in samples.first { $0.time == time } }) ?? samples.last else { return "" }
        let values = Self.charted.compactMap { key in sample.used[key].map { "\(title(key)) \(Int(min($0, 100)))%" } }
        return ([Date(timeIntervalSince1970: sample.time).qishiFormatted()] + values).joined(separator: " · ")
    }
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Self.charted, id: \.self) { key in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(color(key)).frame(width: 12, height: 2.5)
                    Text(title(key))
                }
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
    private func table(_ samples: [DesktopUsageSample]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
                Text(L("记录时间", "Recorded"))
                ForEach(Self.charted, id: \.self) { key in Text(title(key)).gridColumnAlignment(.trailing) }
            }.foregroundStyle(.secondary)
            ForEach(samples, id: \.time) { sample in
                GridRow {
                    Text(Date(timeIntervalSince1970: sample.time).qishiFormatted())
                    ForEach(Self.charted, id: \.self) { key in Text(sample.used[key].map { "\(Int(min($0, 100)))%" } ?? "—").monospacedDigit() }
                }
            }
        }.font(.system(size: 11))
    }
}
