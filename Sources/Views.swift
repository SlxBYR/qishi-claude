import SwiftUI
import AppKit

// Explicit property-wrapper spelling works with the standalone macOS 27 SDK,
// which does not ship the new SwiftUIMacros compiler plug-in.
typealias ViewState<Value> = SwiftUI.State<Value>

extension NSColor {
    /// The Claude logo color, #D97757.
    static let qishiAccent = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
    fileprivate static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        }
    }
}

extension Color {
    static let qishiAccent = Color(nsColor: .qishiAccent)
    // Warm neutrals that sit with the accent. Cards are always one step lighter
    // than the page, in both appearances, so the hierarchy never inverts.
    static let qishiPage = Color(nsColor: .adaptive(light: 0xF5F4EF, dark: 0x1F1E1D))
    static let qishiCard = Color(nsColor: .adaptive(light: 0xFFFFFF, dark: 0x2B2A27, alpha: 0.92))
    static func statusTone(_ name: String) -> Color {
        switch name { case "good": return .green; case "warning": return .orange; case "alert": return .red; default: return .secondary }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("跟随系统", "System"); case .light: return L("浅色", "Light"); case .dark: return L("深色", "Dark") }
    }
    var symbol: String {
        switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" }
    }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

/// Interface theme and language, shared by every window and menu.
@MainActor final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private static let themeKey = "QishiTheme"
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey); applyTheme() }
    }
    @Published var language: AppLanguage {
        didSet { Loc.language = language; languageObservers.forEach { $0() } }
    }
    private var languageObservers: [() -> Void] = []
    private init() {
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .system
        language = Loc.language
    }
    /// AppKit menus, panels and the desktop pets are not SwiftUI views; they
    /// rebuild their text through these callbacks.
    func observeLanguage(_ observer: @escaping () -> Void) { languageObservers.append(observer) }
    func applyTheme() { NSApp.appearance = theme.appearance }
}

struct StatusPill: View {
    var snapshot: MonitorSnapshot
    var checking = false
    var now = Date()
    var body: some View {
        let state = snapshot.status(at: now)
        Label(checking ? L("正在检查", "Checking") : LT(state.title), systemImage: checking ? "arrow.triangle.2.circlepath" : state.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(checking ? Color.secondary : Color.statusTone(state.tone))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(checking ? L("正在检查邮箱", "Checking mailbox") : LT(state.title))
    }
}

struct NativeCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.qishiCard, in: RoundedRectangle(cornerRadius: QishiLayout.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: QishiLayout.cardRadius).stroke(.primary.opacity(0.07), lineWidth: 1) }
    }
}

/// Text-style action in the accent color; `.link` would use the system blue.
struct AccentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color.qishiAccent).opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}
extension ButtonStyle where Self == AccentLinkStyle { static var accentLink: AccentLinkStyle { AccentLinkStyle() } }

/// Usage bar drawn in brand colors so it reads the same in every window state.
struct UsageBar: View {
    var value: Double
    var color: Color = .qishiAccent
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, value / 100)))
            }
        }.frame(height: 6).accessibilityValue("\(Int(value))%")
    }
}

/// One card heading style for every page.
struct CardTitle: View {
    var title: String
    var symbol: String
    var body: some View {
        Label {
            Text(title).font(.system(size: 14, weight: .semibold))
        } icon: {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.qishiAccent)
        }
    }
}

/// A full-width settings switch: label on the leading edge, switch trailing.
struct SettingToggle: View {
    var title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 20)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// Hours, minutes and seconds with their units aligned under each value.
struct ClockReadout: View {
    var elapsed: Elapsed?
    var size: CGFloat = 23
    var showUnits = true
    var body: some View {
        HStack(alignment: .top, spacing: size * 0.25) {
            unit(elapsed?.hours, L("小时", "hr"))
            separator
            unit(elapsed?.minutes, L("分钟", "min"))
            separator
            unit(elapsed?.seconds, L("秒", "sec"))
        }.accessibilityElement(children: .combine)
    }
    private var separator: some View {
        Text(":").font(.system(size: size, weight: .light, design: .rounded)).foregroundStyle(.tertiary)
    }
    private func unit(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value.map { String(format: "%02d", $0) } ?? "—")
                .font(.system(size: size, weight: .light, design: .rounded)).monospacedDigit()
            if showUnits { Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.frame(minWidth: size * 1.3)
    }
}

enum QishiLayout {
    static let sidebarWidth: CGFloat = 188
    // The detail title shares the top chrome; the sidebar brand clears the
    // system window controls without moving every page below them.
    static let pageHeaderTopInset: CGFloat = 12
    static let sidebarTopInset: CGFloat = 52
    static let headerHeight: CGFloat = 56
    static let pageInset: CGFloat = 24
    static let cardSpacing: CGFloat = 18
    static let cardRadius: CGFloat = 18
}

struct PageHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold))
                .accessibilityIdentifier("page-title")
            Spacer(minLength: 8)
            trailing.buttonStyle(.glass)
        }
        .frame(height: QishiLayout.headerHeight, alignment: .center)
        .padding(.horizontal, QishiLayout.pageInset)
        .padding(.top, QishiLayout.pageHeaderTopInset)
        .padding(.bottom, 20)
    }
}

/// Scrolling page body with the shared inset and card spacing.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: QishiLayout.cardSpacing) { content }
                .padding(.horizontal, QishiLayout.pageInset).padding(.bottom, 24)
        }
    }
}

/// Equal-width segments that fill the sidebar; the selection uses the accent.
struct SegmentedChoice<Value: Hashable>: View {
    var options: [(value: Value, symbol: String?, title: String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Group {
                        if let symbol = option.symbol { Image(systemName: symbol) } else { Text(option.title) }
                    }.font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background(selected ? Color.qishiAccent : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(option.title)
                    .accessibilityLabel(option.title).accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }.padding(2).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

// AppKit owns the glass rendering, appearance, contrast, and transparency
// accessibility settings. This backdrop must never intercept sidebar clicks.
struct NativeSidebarGlass: NSViewRepresentable {
    final class Backdrop: NSGlassEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Backdrop {
        let view = Backdrop()
        view.style = .regular
        view.cornerRadius = 0
        view.effectIsInteractive = false
        return view
    }
    func updateNSView(_ view: Backdrop, context: Context) {}
}

struct QishiSidebar: View {
    @Binding var selection: Int
    @ObservedObject var prefs = AppPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "hourglass").font(.system(size: 22, weight: .medium)).foregroundStyle(Color.qishiAccent)
                    .frame(width: 42, height: 42).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 13))
                Text(L("栖时", "Qishi")).font(.system(size: 21, weight: .semibold))
            }.frame(height: QishiLayout.headerHeight)
            VStack(spacing: 6) {
                nav(L("Claude 工作台", "Claude"), symbol: "sparkles", page: 2)
                nav(L("桌宠与接入", "Companions"), symbol: "person.2", page: 3)
                nav(L("账户守护", "Account"), symbol: "square.grid.2x2", page: 0)
                nav(L("连接与计时", "Connection"), symbol: "slider.horizontal.3", page: 1)
            }
            Spacer()
            VStack(spacing: 8) {
                SegmentedChoice(options: AppTheme.allCases.map { ($0, $0.symbol, $0.title) }, selection: $prefs.theme)
                    .accessibilityIdentifier("theme-picker")
                SegmentedChoice(options: [(AppLanguage.zh, nil, "中文"), (AppLanguage.en, nil, "EN")], selection: $prefs.language)
                    .accessibilityIdentifier("language-picker")
            }
        }.padding(.horizontal, 16).padding(.top, QishiLayout.sidebarTopInset).padding(.bottom, 20).frame(width: QishiLayout.sidebarWidth)
            .frame(maxHeight: .infinity)
            // The glass draws a rim along its own edges. Bleeding it past the
            // sidebar tucks that rim under the opaque page (later in the
            // HStack, so drawn on top) and outside the window bounds.
            .background(NativeSidebarGlass().padding(-QishiLayout.pageInset))
    }
    func nav(_ title: String, symbol: String, page: Int) -> some View {
        let selected = selection == page
        return Button { selection = page } label: {
            Label {
                Text(title).foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            } icon: {
                Image(systemName: symbol).foregroundStyle(selected ? Color.qishiAccent : Color.secondary).frame(width: 18)
            }.font(.system(size: 13, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(selected ? Color.qishiAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                // The hit region is the entire highlighted row, including its
                // padding, not just the image and text of a plain Button.
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-\(page)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct QishiRoot: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var prefs = AppPreferences.shared
    var body: some View {
        HStack(spacing: 0) {
            // No Divider here: the window itself is transparent, so a separate
            // separator view left a see-through seam. The hairline is drawn
            // inside the sidebar, over an opaque root background.
            QishiSidebar(selection: $store.selectedPage)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
            Group {
                if store.selectedPage == 2 { ClaudeWorkView(claude: claude, monitor: store) }
                else if store.selectedPage == 3 { ClaudeSettingsView(claude: claude) }
                else if store.selectedPage == 0 { DashboardView(store: store) }
                else { ConnectionView(store: store) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.qishiPage)
                // Pages read the language when their body is built; a new
                // identity rebuilds them all at once after a switch.
                .id(prefs.language)
        }.frame(minWidth: 920, minHeight: 700)
            .background(Color.qishiPage)
            .ignoresSafeArea(.container, edges: .top)
            .tint(.qishiAccent)
            .environment(\.locale, Loc.locale)
            .alert(L("栖时", "Qishi"), isPresented: Binding(get: { store.message != nil || claude.message != nil }, set: { if !$0 { store.message = nil; claude.message = nil } })) {
                Button(L("好", "OK"), role: .cancel) { store.message = nil; claude.message = nil }
            } message: { Text(LT(store.message ?? claude.message ?? "")) }
    }
}

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("账户守护", "Account")) {
                Button { Task { await store.check() } } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                    .controlSize(.large).help(L("立即检查 Gmail", "Check Gmail now"))
                    .accessibilityLabel(L("立即检查 Gmail", "Check Gmail now"))
                    .disabled(store.isChecking || !store.settings.isConfigured || !store.settings.monitoring)
            }
            PageScroll {
                NativeCard {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            CardTitle(title: L("注册至今", "Since registration"), symbol: "hourglass")
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                StatusPill(snapshot: store.snapshot, checking: store.isChecking, now: context.date)
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = store.settings.registeredAt.map { Elapsed(since: $0, now: context.date) }
                            HStack(alignment: .center, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(elapsed.map { String($0.days) } ?? "—").font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                                    Text(L("天", "days")).font(.system(size: 17)).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                                Spacer()
                                ClockReadout(elapsed: elapsed)
                            }
                        }
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "calendar").foregroundStyle(.secondary)
                            if let date = store.settings.registeredAt {
                                Text(L("始于 ", "Started ") + date.qishiFormatted())
                            } else { Text(L("尚未设置注册时间", "Registration time not set")) }
                            Spacer()
                            Button(store.settings.registeredAt == nil ? L("设置", "Set") : L("编辑", "Edit")) { store.selectedPage = 1 }.buttonStyle(.accentLink)
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "envelope.badge.shield.half.filled").font(.system(size: 22)).foregroundStyle(Color.qishiAccent)
                            Text(store.settings.email.isEmpty ? L("连接你的 Gmail", "Connect your Gmail") : store.settings.email)
                                .font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                            Spacer()
                        }
                        if let error = store.snapshot.error {
                            Label(LT(error), systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = store.storageError { Text(LT(error)).font(.system(size: 12)).foregroundStyle(.red) }
                        if let hit = store.snapshot.hits.first {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(LT(hit.subject)).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                                Text("\(hit.sender) · \(hit.receivedAt.qishiFormatted())").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(L("最近成功检查发现 \(store.snapshot.hits.count) 封匹配邮件，请在 Gmail 核实内容。",
                                       "The last successful check found \(store.snapshot.hits.count) matching email(s). Please verify them in Gmail."))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        HStack {
                            if store.settings.isConfigured {
                                Button(L("在 Gmail 查看", "Open in Gmail"), systemImage: "arrow.up.right") { store.openGmail() }.buttonStyle(.bordered)
                                Spacer()
                                Button(store.settings.monitoring ? L("暂停检测", "Pause monitoring") : L("继续检测", "Resume monitoring")) { store.setMonitoring(!store.settings.monitoring) }.buttonStyle(.accentLink)
                            } else {
                                Button(L("连接 Gmail", "Connect Gmail"), systemImage: "link") { store.selectedPage = 1 }.buttonStyle(.borderedProminent)
                                Spacer()
                            }
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                            if let checked = store.snapshot.lastChecked {
                                Text(L("最近成功检查：", "Last successful check: ") + checked.qishiFormatted())
                            } else { Text(L("尚未完成首次检查", "No check completed yet")) }
                            Spacer()
                            Text(L("每 \(store.settings.intervalMinutes) 分钟", "Every \(store.settings.intervalMinutes) min"))
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                NativeCard {
                    HStack {
                        CardTitle(title: L("桌面卡片", "Desktop card"), symbol: "rectangle.on.rectangle")
                        Spacer()
                        Toggle(L("显示桌面卡片", "Show desktop card"), isOn: Binding(get: { store.settings.desktopCard }, set: store.setDesktop))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(width: 116, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var store: MonitorStore
    @ViewState private var email = ""
    @ViewState private var password = ""
    @ViewState private var registration = Date()
    @ViewState private var interval = 5
    @ViewState private var formError: String?
    @ViewState private var confirmDisconnect = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L("连接与计时", "Connection & Timer")) { EmptyView() }
            PageScroll {
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: L("Gmail 邮箱", "Gmail"), symbol: "envelope")
                        SettingsRow(title: L("邮箱地址", "Email")) {
                            TextField(L("邮箱地址", "Email"), text: $email, prompt: Text("name@gmail.com"))
                                .textContentType(.username).labelsHidden().accessibilityLabel(L("邮箱地址", "Email"))
                        }
                        SettingsRow(title: L("应用专用密码", "App password")) {
                            SecureField(L("应用专用密码", "App password"), text: $password,
                                        prompt: Text(store.settings.email.isEmpty ? L("16 位应用专用密码", "16-character app password") : L("留空以使用已保存密码", "Leave empty to keep the saved one")))
                                .textContentType(.password).labelsHidden().accessibilityLabel(L("应用专用密码", "App password"))
                        }
                        Link(L("获取应用专用密码", "Get an app password"), destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                            .font(.system(size: 12)).foregroundStyle(Color.qishiAccent).padding(.leading, 128)
                    }.textFieldStyle(.roundedBorder)
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: L("注册计时", "Registration timer"), symbol: "hourglass")
                        SettingsRow(title: L("账号注册时间", "Registered at")) {
                            DatePicker(L("账号注册时间", "Registered at"), selection: $registration, in: ...Date(), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                        }
                        SettingsRow(title: L("检查间隔", "Check interval")) {
                            Picker(L("检查间隔", "Check interval"), selection: $interval) {
                                Text(L("1 分钟", "1 min")).tag(1)
                                Text(L("5 分钟 · 推荐", "5 min · recommended")).tag(5)
                                Text(L("15 分钟", "15 min")).tag(15)
                                Text(L("30 分钟", "30 min")).tag(30)
                            }.labelsHidden().frame(width: 200, alignment: .leading)
                        }
                        if store.settings.email.isEmpty {
                            Button(L("仅保存注册时间", "Save registration time only")) {
                                do { try store.saveRegistration(registration); formError = nil }
                                catch { formError = error.localizedDescription }
                            }.buttonStyle(.bordered).padding(.leading, 128)
                        }
                    }
                }
                NativeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(title: L("显示与提醒", "Display & alerts"), symbol: "macwindow")
                        SettingToggle(title: L("隐藏 Dock 图标", "Hide Dock icon"), isOn: Binding(get: { store.settings.hideDockIcon }, set: store.setHideDockIcon))
                        Divider()
                        SettingToggle(title: L("显示桌面卡片", "Show desktop card"), isOn: Binding(get: { store.settings.desktopCard }, set: store.setDesktop))
                        SettingToggle(title: L("卡片保持在其他窗口上方", "Keep card above other windows"), isOn: Binding(get: { store.settings.alwaysOnTop }, set: store.setOnTop))
                            .disabled(!store.settings.desktopCard)
                        SettingToggle(title: L("发现新匹配邮件时通知", "Notify on new matching email"), isOn: Binding(get: { store.settings.notify }, set: store.setNotifications))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if let formError {
                    Label(LT(formError), systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if let storageError = store.storageError {
                    Label(LT(storageError), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !store.settings.email.isEmpty { Button(L("断开连接", "Disconnect"), role: .destructive) { confirmDisconnect = true }.buttonStyle(.glass) }
                    Spacer()
                    Button(L("保存并检查", "Save and check")) {
                        do { try store.apply(email: email, password: password, registered: registration, interval: interval); password = ""; formError = nil }
                        catch { formError = error.localizedDescription }
                    }.buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                }
            }.padding(.horizontal, QishiLayout.pageInset).padding(.vertical, 16)
                .background(.bar).overlay(alignment: .top) { Divider() }
        }.onAppear { email = store.settings.email; registration = store.settings.registeredAt ?? Date(); interval = store.settings.intervalMinutes }
            .confirmationDialog(L("断开 Gmail 并移除本机保存的密码？", "Disconnect Gmail and remove the saved password?"), isPresented: $confirmDisconnect) {
                Button(L("断开并移除密码", "Disconnect and remove"), role: .destructive) { do { try store.disconnect(); email = ""; password = "" } catch { formError = error.localizedDescription } }
            } message: { Text(L("注册时间会保留。你可以稍后重新连接。", "The registration time is kept. You can reconnect later.")) }
    }
}

struct DesktopCardView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var prefs = AppPreferences.shared
    var open: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = store.settings.registeredAt.map { Elapsed(since: $0, now: context.date) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label {
                        Text(L("栖时", "Qishi")).font(.system(size: 13, weight: .semibold))
                    } icon: { Image(systemName: "hourglass").foregroundStyle(Color.qishiAccent) }
                    Spacer()
                    Button(action: open) { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(L("打开栖时", "Open Qishi")).accessibilityLabel(L("打开栖时", "Open Qishi"))
                }
                HStack(alignment: .center, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(elapsed.map { String($0.days) } ?? "—").font(.system(size: 46, weight: .light, design: .rounded)).monospacedDigit()
                        Text(L("天", "days")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ClockReadout(elapsed: elapsed, size: 17, showUnits: false)
                }
                HStack {
                    StatusPill(snapshot: store.snapshot, checking: store.isChecking, now: context.date)
                    Spacer()
                    if let last = store.snapshot.lastChecked { Text(last, style: .time).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(store.settings.email.isEmpty ? L("连接 Gmail，设置注册时间", "Connect Gmail and set the registration time") : store.settings.email)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(20).frame(width: 344, height: 196)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                .contentShape(RoundedRectangle(cornerRadius: 24))
                .onTapGesture(count: 2, perform: open)
        }.padding(8)
            .id(prefs.language)
            .tint(.qishiAccent)
            .environment(\.locale, Loc.locale)
    }
}
