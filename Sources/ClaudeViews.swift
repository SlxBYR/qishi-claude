import SwiftUI
import AppKit
import ImageIO

@MainActor enum ClaudeArt {
    static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Claude/\(name).webp"), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image; return image
    }
}
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
struct ClawdPet: View {
    @ObservedObject var claude: ClaudeStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var name: String {
        if claude.pose == .asking { return "notification" }
        if claude.busyCount > 1 || (claude.focus?.agents.count ?? 0) > 1 { return "juggling" }
        switch claude.pose {
        case .thinking: return "thinking"
        case .reading, .searching: return "idle-reading"
        case .writing: return "typing"
        case .running: return "building"
        case .delegating: return "headphones-groove"
        case .compact: return "sweeping"
        case .happy: return "happy"
        case .error: return "error"
        case .sleeping: return "sleeping"
        default: return "idle"
        }
    }
    var body: some View {
        OriginalClawdAnimation(name: name, animate: !reduceMotion)
            .frame(width: 112, height: 112).clipped()
            .accessibilityElement(children: .ignore).accessibilityLabel("Clawd, \(LT(claude.pose.title))")
    }
}
struct ClaudeDuo: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var monitor: MonitorStore
    @ViewState private var accountVisible = false
    @ViewState private var accountInteraction = UUID()
    var height: CGFloat = 220
    var body: some View {
        HStack(alignment: .bottom, spacing: -20) {
            Button {
                claude.pat(); accountVisible = true; accountInteraction = UUID()
            } label: {
                Group {
                    if let img = ClaudeArt.image(claude.petAsset) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else { Image(systemName: "person.crop.circle").resizable().aspectRatio(contentMode: .fit).padding(50) }
                }.frame(width: height * 0.85, height: height)
            }.buttonStyle(.plain)
                .accessibilityLabel(L("Claude 娘，查看账号存活天数", "Claude-chan: show account age"))
                .help(L("查看账号存活天数", "Show account age"))
                .overlay(alignment: .top) {
                    if accountVisible {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            // An in-character speech bubble: it keeps the
                            // CrossPet paper look in both appearances.
                            Text(monitor.settings.registeredAt.map { accountAge(Elapsed(since: $0, now: context.date).days) } ?? L("请先设置账号注册时间", "Set the registration time first"))
                                .font(.system(size: 13)).monospacedDigit()
                                .foregroundStyle(Color(red: 74/255, green: 36/255, blue: 24/255))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Color.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.qishiAccent, lineWidth: 1.5) }
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                                .onTapGesture { accountVisible = false }
                        }.offset(y: -8)
                    }
                }
            ClawdPet(claude: claude).padding(.bottom, 14).onTapGesture { claude.pat() }
        }.onExitCommand { accountVisible = false }
            .task(id: accountInteraction) {
                guard accountVisible else { return }
                do { try await Task.sleep(for: .seconds(8)); accountVisible = false } catch {}
            }
    }
    private func accountAge(_ days: Int) -> String { L("账号已存活 \(days) 天", days == 1 ? "Account alive for 1 day" : "Account alive for \(days) days") }
}
struct ClaudeWorkView: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var monitor: MonitorStore
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Claude 工作台", "Claude Workbench")) {
                Button { claude.openClaude() } label: { Label(L("打开 Claude", "Open Claude"), systemImage: "arrow.up.forward.app") }
            }
            PageScroll {
                if claude.preview {
                    Label(L("界面预览 · 示例数据", "Interface preview · sample data"), systemImage: "photo")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                NativeCard {
                    HStack(spacing: 18) {
                        ClaudeDuo(claude: claude, monitor: monitor, height: 208)
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
                                if !claude.connected {
                                    Button(L("接入 Claude Code", "Connect Claude Code")) { claude.connect(true) }.buttonStyle(.borderedProminent)
                                }
                                Button(claude.preferences.showPet ? L("收起桌面伙伴", "Hide companions") : L("显示桌面伙伴", "Show companions")) {
                                    claude.preferences.showPet.toggle(); claude.save()
                                }.buttonStyle(.bordered)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity)
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
                        Button(L("查看", "View")) { monitor.selectedPage = 0 }.buttonStyle(.bordered)
                    }
                }
                if !claude.state.events.isEmpty {
                    NativeCard {
                        VStack(alignment: .leading, spacing: 10) {
                            CardTitle(title: L("最近活动", "Recent activity"), symbol: "clock.arrow.circlepath")
                            ForEach(Array(claude.state.events.suffix(6).reversed())) { event in
                                HStack(spacing: 12) {
                                    Text(LT(event.project)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(LT(event.title) + (event.tool.isEmpty ? "" : " · \(event.tool)")).lineLimit(1)
                                    Text(Date(timeIntervalSince1970: event.time), style: .time).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                                }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
            UsageBar(value: q.used, color: q.used >= 90 ? .red : q.used >= 70 ? .orange : .qishiAccent)
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
                    Button(L("回 Claude 处理", "Handle in Claude")) { claude.decide(request, choice: "native"); claude.openClaude() }.buttonStyle(.bordered)
                    Spacer()
                    Button(L("拒绝", "Deny"), role: .destructive) { claude.decide(request, choice: "deny") }.buttonStyle(.bordered)
                    Button(L("允许一次", "Allow once")) { claude.decide(request, choice: "allow") }.buttonStyle(.borderedProminent)
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
        VStack(spacing: 0) {
            PageHeader(title: L("桌宠与接入", "Companions & Integration")) { EmptyView() }
            PageScroll {
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: "Claude Code", symbol: "link")
                        HStack(spacing: 10) {
                            Label(claude.connected ? L("已接入", "Connected") : L("尚未接入", "Not connected"),
                                  systemImage: claude.connected ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 13)).foregroundStyle(claude.connected ? Color.green : Color.secondary)
                            Spacer()
                            if claude.connected { Button(L("撤销接入", "Disconnect")) { claude.connect(false) }.buttonStyle(.bordered) }
                            Button(claude.connected ? L("修复接入", "Repair") : L("接入 Claude Code", "Connect Claude Code")) { claude.connect(true) }.buttonStyle(.borderedProminent)
                        }
                        Button(L("查看接入备份", "Show integration backups"), systemImage: "folder") {
                            NSWorkspace.shared.open(ClaudeFiles.root.appendingPathComponent("Backups"))
                        }.buttonStyle(.accentLink).font(.system(size: 12))
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: L("桌面伙伴", "Desktop companions"), symbol: "sparkles")
                        toggle(L("显示 Claude 娘与 Clawd", "Show Claude-chan and Clawd"), \.showPet)
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
        }
    }
    private func toggle(_ title: String, _ key: WritableKeyPath<ClaudePreferences, Bool>) -> some View {
        SettingToggle(title: title, isOn: Binding(get: { claude.preferences[keyPath: key] }, set: { claude.preferences[keyPath: key] = $0; claude.save() }))
    }
}
struct ClaudePetView: View {
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var monitor: MonitorStore
    var body: some View {
        VStack(spacing: 2) {
            if !claude.preferences.compact { ClaudeDuo(claude: claude, monitor: monitor, height: 205) }
            Button { claude.showMain?() } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: claude.pose.symbol).foregroundStyle(Color.qishiAccent)
                        Text("Claude & Clawd").fontWeight(.semibold)
                        Spacer(minLength: 8)
                        Text(LT(claude.pose.title)).foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                    if let q = claude.focus, let ts = q.quotaUpdated {
                        HStack {
                            ForEach(q.quota.prefix(2)) { limit in
                                Text(L("\(limit.id == "five_hour" ? "5h" : "7d") 剩 \(Int(100 - limit.used))%", "\(limit.id == "five_hour" ? "5h" : "7d") \(Int(100 - limit.used))% left"))
                            }
                            if claude.now.timeIntervalSince1970 - ts > 900 { Text(L("· 旧数据", "· stale")) }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(13).frame(width: 280).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain).help(L("打开 Claude 工作台", "Open the Claude workbench"))
        }.padding(12)
            .contextMenu {
                Button(L("打开工作台", "Open workbench")) { claude.showMain?() }
                Button(L("摸摸头", "Pat")) { claude.pat() }
                Button(claude.preferences.compact ? L("展开两位伙伴", "Show both companions") : L("收起为状态条", "Collapse to status bar")) { claude.preferences.compact.toggle(); claude.save() }
                Button(L("暂时隐藏", "Hide for now")) { claude.preferences.showPet = false; claude.save() }
            }
    }
}
