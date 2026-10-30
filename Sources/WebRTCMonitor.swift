import AppKit
import WebKit

/// Checks browserleaks.com/webrtc in an offscreen WebKit view. The page runs its
/// own WebRTC probe; only its result table (leak verdict and IPs) is read back.
@MainActor final class WebRTCMonitor: ObservableObject {
    enum Status: Equatable {
        case idle, checking, noLeak, leak(String), failed(String)
        var isLeak: Bool { if case .leak = self { return true }; return false }
    }
    static let page = URL(string: "https://browserleaks.com/webrtc")!
    static let interval: TimeInterval = 5 * 60
    @Published private(set) var status: Status = .idle
    @Published private(set) var publicIP: String?
    @Published private(set) var checkedAt: Date?
    let preview: Bool
    private var web: WKWebView?
    private var task: Task<Void, Never>?
    private var timer: Timer?

    init(preview: Bool = false) {
        self.preview = preview
        if preview { status = .noLeak; publicIP = "203.0.113.8"; checkedAt = Date() }
    }

    func start() {
        guard !preview, timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); web = nil }

    func check() {
        guard !preview, status != .checking else { return }
        status = .checking
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        self.web = web
        web.load(URLRequest(url: Self.page, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        task = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let result = await self.read(web) else { continue }
                self.finish(result); return
            }
            self?.finish(nil)
        }
    }

    private struct Result: Decodable { var leak: String?; var publicIP: String?; var remoteIP: String? }

    /// The verdict cell is `#rtc-leak`; the WebRTC public address sits in the
    /// "Public IP Address" row of the same table.
    private func read(_ web: WKWebView) async -> Result? {
        let script = """
        (() => {
          const rows = [...document.querySelectorAll('tr')];
          const cell = label => { const row = rows.find(r => r.children[0]?.innerText.trim() === label);
            return row && row.children[1] ? row.children[1].innerText.trim() : null; };
          const leak = document.getElementById('rtc-leak');
          return JSON.stringify({ leak: leak ? leak.innerText.replace(/[\\u2714\\u2716\\u2718\\u00d7]/g, '').trim() : null,
            publicIP: cell('Public IP Address'), remoteIP: document.getElementById('client-ipv4')?.innerText.trim() ?? null });
        })()
        """
        guard let json = try? await web.evaluateJavaScript(script) as? String,
              let result = try? JSONDecoder().decode(Result.self, from: Data(json.utf8)),
              let leak = result.leak, !leak.isEmpty, leak != "-" else { return nil }
        return result
    }

    private func finish(_ result: Result?) {
        web = nil
        checkedAt = Date()
        guard let result, let leak = result.leak else { status = .failed(L("无法读取检测结果", "Could not read the result")); return }
        let ip = result.publicIP.flatMap { $0 == "-" || $0.isEmpty ? nil : $0 }
        publicIP = ip ?? result.remoteIP
        status = leak.range(of: "no leak", options: .caseInsensitive) != nil ? .noLeak : .leak(leak)
    }
}
