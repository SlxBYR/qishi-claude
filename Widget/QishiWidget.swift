import SwiftUI
import WidgetKit

struct QishiEntry: TimelineEntry { let date: Date; let snapshot: MonitorSnapshot; var preview = false }
struct QishiProvider: TimelineProvider {
    func placeholder(in context: Context) -> QishiEntry { example() }
    func getSnapshot(in context: Context, completion: @escaping (QishiEntry) -> Void) {
        completion(context.isPreview ? example() : QishiEntry(date: .now, snapshot: SharedSnapshotStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QishiEntry>) -> Void) {
        let snapshot = SharedSnapshotStore.read()
        let now = Date()
        let entries = (0..<5).map { QishiEntry(date: now.addingTimeInterval(Double($0 * 300)), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1200))))
    }
    private func example() -> QishiEntry {
        var snapshot = MonitorSnapshot()
        snapshot.registeredAt = Date().addingTimeInterval(-27 * 86400)
        return QishiEntry(date: .now, snapshot: snapshot, preview: true)
    }
}

struct QishiWidgetView: View {
    let entry: QishiEntry
    @Environment(\.widgetFamily) var family
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("栖时", systemImage: "hourglass").font(.caption.weight(.semibold))
                Spacer()
                if family == .systemMedium { Text("ANTHROPIC").font(.caption2).foregroundStyle(.secondary) }
            }
            if let date = entry.snapshot.registeredAt {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(Elapsed(since: date, now: entry.date).days)).font(.system(size: 43, weight: .light, design: .rounded)).monospacedDigit()
                    Text("天").font(.caption).foregroundStyle(.secondary)
                    if family == .systemMedium {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("注册至今").font(.caption2).foregroundStyle(.secondary)
                            Text(date, style: .timer).font(.system(.body, design: .rounded)).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                    }
                }
            } else { Text("从今天\n开始记录").font(.title3.weight(.medium)) }
            Spacer(minLength: 0)
            let state = entry.snapshot.status(at: entry.date)
            Label(entry.preview ? "设置你的注册时间" : state.title, systemImage: state.symbol)
                .font(.caption2).foregroundStyle(state.tone == "alert" ? .red : state.tone == "warning" ? .orange : .secondary)
            if family == .systemMedium {
                if let checked = entry.snapshot.lastChecked {
                    Text("上次成功检查 \(checked.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                } else { Text("打开栖时完成邮箱连接").font(.caption2).foregroundStyle(.secondary) }
            }
        }.containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "qishi://open"))
    }
}

@main struct QishiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QishiWidget", provider: QishiProvider()) { entry in QishiWidgetView(entry: entry) }
            .configurationDisplayName("栖时 · 账号时光")
            .description("注册至今的时间，以及最近一次 Anthropic 邮件检查结果。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
