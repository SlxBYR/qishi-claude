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
        let size: [Double]; let center: [Double]; let spokes: [Spoke]
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
/// The workbench mark. Every ray of the Claude starburst stretches and
/// settles along its own axis on its own rhythm, so the star breathes in many
/// directions at once; widths never change and the centre stays put. It
/// quickens while Claude works and holds still with Reduce Motion.
struct ClaudeLogoView: View {
    var busy: Bool
    var size: CGFloat = 200
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        Group {
            if let layout = ClaudeLogoArt.layout {
                let anchor = UnitPoint(x: layout.center[0] / layout.size[0], y: layout.center[1] / layout.size[1])
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate * (busy ? 1.9 : 1)
                    ZStack {
                        layer("hub.png")
                        ForEach(layout.spokes.indices, id: \.self) { index in
                            let angle = Angle.degrees(layout.spokes[index].angle)
                            // Rotate the ray onto the x axis, stretch only its length, rotate back.
                            layer(layout.spokes[index].file)
                                .rotationEffect(-angle, anchor: anchor)
                                .scaleEffect(x: reduceMotion ? 1 : stretch(index, time), y: 1, anchor: anchor)
                                .rotationEffect(angle, anchor: anchor)
                        }
                    }
                }
            } else {
                Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(Color.qishiAccent)
            }
        }.frame(width: size, height: size)
            .accessibilityElement().accessibilityLabel("Claude")
    }
    /// Two incommensurate waves per ray with golden-ratio phases: neighbours
    /// never move in step, so no rotating wave appears.
    private func stretch(_ index: Int, _ time: Double) -> CGFloat {
        let seed = Double(index) * 0.618_033_988_75
        let speed = 0.75 + (seed.truncatingRemainder(dividingBy: 1)) * 0.6
        let phase = seed * 2 * .pi
        let wave = 0.62 * sin(time * speed * 1.7 + phase) + 0.38 * sin(time * speed * 3.9 + phase * 2.3)
        return CGFloat(1 + 0.13 * wave)
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
                        Divider()
                        ClaudeDesktopUsageSection(reader: claude.desktop)
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: L("会话", "Sessions"), symbol: "square.stack.3d.up")
                        if claude.sessions.isEmpty {
                            Text(L("暂无会话", "No sessions yet")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(claude.sessions) { session in sessionRow(session) }
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
/// Limits read from Claude Desktop: live while it runs, the last reading otherwise.
struct ClaudeDesktopUsageSection: View {
    @ObservedObject var reader: ClaudeDesktopReader
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Claude Desktop", systemImage: "macwindow").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !reader.trusted {
                HStack(alignment: .top, spacing: 12) {
                    Text(L("需要“辅助功能”权限才能读取 Claude 界面上显示的额度。", "Accessibility permission is needed to read the limits Claude shows."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("授予权限", "Grant access")) { reader.requestAccess() }.buttonStyle(.glass)
                }
            }
            if let snapshot = reader.snapshot {
                ForEach(snapshot.quotas) { quota in row(quota) }
                    .opacity(reader.running ? 1 : 0.7)
            } else if reader.trusted {
                Text(L("在 Claude 中打开 设置 → 用量，即会自动读取并保存。", "Open Settings → Usage in Claude; the limits are read and kept automatically."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var status: String {
        let time = reader.snapshot.map { $0.capturedAt.qishiFormatted(date: .abbreviated, time: .shortened) }
        if reader.running { return L("运行中", "Running") + (time.map { L(" · 读取于 ", " · read ") + $0 } ?? "") }
        return L("未运行", "Not running") + (time.map { L(" · 上次数据 ", " · last data ") + $0 } ?? "")
    }
    private func title(_ id: String) -> String {
        switch id {
        case "five_hour": return L("当前会话", "Current session")
        case "seven_day": return L("每周 · 所有模型", "Weekly · all models")
        case "seven_day_opus": return L("每周 · Opus", "Weekly · Opus")
        case "seven_day_sonnet": return L("每周 · Sonnet", "Weekly · Sonnet")
        default: return id
        }
    }
    private func row(_ quota: DesktopQuota) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title(quota.id)).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(L("已用 \(Int(quota.used))% · 剩余 \(Int(100 - quota.used))%", "\(Int(quota.used))% used · \(Int(100 - quota.used))% left")).font(.system(size: 12)).monospacedDigit()
            }
            ProgressView(value: quota.used, total: 100).tint(quota.used >= 90 ? .red : quota.used >= 70 ? .orange : .qishiAccent)
            if let reset = quota.reset { Text(reset).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
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
