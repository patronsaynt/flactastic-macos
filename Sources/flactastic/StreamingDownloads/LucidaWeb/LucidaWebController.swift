import Foundation
import WebKit
import AppKit
import Observation
import os

let lucidaLog = Logger(subsystem: "com.flactastic.app", category: "Lucida")

/// Thin host for a hidden `WKWebView` pointed at https://lucida.to.
///
/// Why a WebView at all: lucida.to's `/api/load`, `/api/fetch/*`, and the file
/// CDN are all behind Cloudflare's bot challenge. A real browser passes the
/// JS challenge and obtains a `cf_clearance` cookie. Driving the page from
/// inside `WKWebView` (cookies + matching TLS fingerprint + UA) lets us hit
/// the same JSON API the website uses, with zero user setup.
///
/// All public methods are `async`; under the hood they bounce JSON through
/// `evaluateJavaScript`, calling the `__flac` helpers we inject on first load.
@MainActor
@Observable
final class LucidaWebController: NSObject {

    /// State machine. `ready` means the page finished loading *and* our
    /// helper script was injected — i.e. the bridge methods are usable.
    enum Phase: Equatable {
        case idle, loading, ready, failed(String)
    }

    private(set) var phase: Phase = .idle

    /// True when the last navigation landed on a Cloudflare challenge that
    /// requires a real user click (Turnstile checkbox). The UI observes this
    /// and surfaces the WebView in a sheet so the user can clear it once,
    /// in-app — no debug menu detour. Flips back to `false` automatically
    /// once `phase` reaches `.ready`.
    private(set) var needsUserChallenge: Bool = false

    /// Append-only ring of debug events (navigation, bridge calls, errors).
    /// Capped at 200 entries so the debug window stays responsive on long
    /// sessions. Surfaced via the View → "Enable Debugging" pane.
    struct LogEntry: Identifiable, Hashable {
        let id = UUID()
        let timestamp = Date()
        let kind: Kind
        let message: String
        enum Kind: String { case nav, bridge, ok, error, info }
    }
    private(set) var log: [LogEntry] = []

    func addLog(_ kind: LogEntry.Kind, _ message: String) {
        // Mirrored to the unified log so a failure can be traced after the
        // fact (`log show --predicate 'subsystem == "com.flactastic.app"'`),
        // not only while the debug pane is open.
        if kind == .error {
            lucidaLog.error("\(kind.rawValue, privacy: .public) \(message, privacy: .public)")
        } else {
            lucidaLog.log("\(kind.rawValue, privacy: .public) \(message, privacy: .public)")
        }
        log.append(LogEntry(kind: kind, message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func clearLog() { log.removeAll() }

    /// Continuations awaiting `.ready`. We collect them rather than poll.
    @ObservationIgnored
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// True once a Cloudflare challenge sheet has been auto-surfaced during
    /// this app session. Subsequent CF interstitials (e.g. mid-session cookie
    /// expiry) are not re-prompted — they fall through to normal error paths.
    /// Resets naturally on next app launch since the controller is recreated.
    @ObservationIgnored
    private var hasPromptedThisSession: Bool = false

    /// Created on first access, not at controller construction: the WKWebView
    /// spawns a WebKit content process (and a hidden host window), which is
    /// pure launch-time overhead for users who never open the Downloads tab.
    /// Every code path that needs the web view goes through this accessor —
    /// `warmUp()` (Downloads tab appear), the bridge calls, and the debug /
    /// challenge sheets — so behavior past that first touch is unchanged.
    @ObservationIgnored private var _webView: WKWebView?
    var webView: WKWebView {
        if let _webView { return _webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent cookies across launches
        // Hidden frame; we never display it.
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768),
                                configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Web Inspector access from the debug window (Right-click → Inspect
        // Element). Requires macOS 13.3+; harmless on older OSes.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        // Off-screen attach. WKWebView doesn't tick layout / JS reliably until
        // it's in a window; the simplest cure is a 1×1 hidden NSWindow.
        Self.host(webView)
        _webView = webView
        return webView
    }

    private static let entryURL = URL(string: "https://lucida.to/")!
    /// User-Agent we mirror for any out-of-WebView requests (so cookies +
    /// fingerprint stay consistent with the cleared session).
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Begin loading lucida.to (idempotent). Call from the app's bootstrap.
    func warmUp() {
        guard phase == .idle else { return }
        phase = .loading
        addLog(.nav, "load \(Self.entryURL.absoluteString)")
        webView.load(URLRequest(url: Self.entryURL))
    }

    /// Force a reload — useful from the debug pane after a CF challenge
    /// blocked the first attempt.
    func reload() {
        addLog(.nav, "reload (phase=\(phase))")
        phase = .loading
        webView.load(URLRequest(url: Self.entryURL))
    }

    /// Wipe all WebKit storage (cookies, cache, localStorage) for lucida.to
    /// and reset to idle so the next warmUp() triggers a fresh CF negotiation.
    /// Intended for the debug pane — lets you reproduce the first-load
    /// Cloudflare challenge without restarting the app.
    func clearSiteData() {
        addLog(.info, "clearing site data…")
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phase = .idle
                self.hasPromptedThisSession = false
                self.needsUserChallenge = false
                self.addLog(.ok, "site data cleared; ready to warmUp()")
            }
        }
    }

    /// Suspend until the bridge is usable. Throws if the load failed.
    func awaitReady() async throws {
        switch phase {
        case .ready: return
        case .failed(let msg): throw StreamerError.unavailable("Lucida unavailable: \(msg)")
        case .idle: warmUp(); fallthrough
        case .loading:
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                readyWaiters.append(cont)
            }
        }
    }

    private func resolveWaiters(_ result: Result<Void, Error>) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume(with: result) }
    }

    // MARK: - JS bridge

    /// Run the helper expression and decode the JSON it resolves with.
    /// Helpers are defined in `bridgeScript` below; each takes care of
    /// success/error normalisation so callers see a consistent envelope.
    func callBridge<T: Decodable>(_ expr: String, as: T.Type = T.self) async throws -> T {
        try await awaitReady()
        addLog(.bridge, expr.prefix(220).description)
        do {
            let str = try await evaluateString(expr)
            guard let data = str.data(using: .utf8) else {
                throw StreamerError.decoding("non-utf8 bridge payload")
            }
            let env = try JSONDecoder().decode(BridgeEnvelope<T>.self, from: data)
            if !env.ok {
                addLog(.error, "bridge !ok: \(env.error ?? "<nil>")")
                throw StreamerError.unavailable(env.error ?? "lucida bridge error")
            }
            guard let v = env.value else {
                throw StreamerError.decoding("bridge ok=true but value missing")
            }
            // Include a truncated preview so the debug pane reveals what
            // lucida actually returned — invaluable for diagnosing missing
            // metadata fields without re-running with extra logging.
            let preview = str.count > 600 ? "\(str.prefix(600))…" : str
            addLog(.ok, "bridge ok (\(str.count) chars): \(preview)")
            return v
        } catch {
            addLog(.error, "bridge threw: \(error)")
            throw error
        }
    }

    /// Run an async expression and return its resolved string value.
    ///
    /// `evaluateJavaScript` does NOT await Promises — it errors out with
    /// "result of an unsupported type". `callAsyncJavaScript` runs the body
    /// as an async function and awaits the returned Promise on the JS side
    /// before bridging the result back. The bridge helpers always resolve
    /// to a JSON-stringified envelope (see `bridgeScript`), so we narrow to
    /// `String` for Sendable safety.
    private func evaluateString(_ expr: String) async throws -> String {
        let body = "return await (\(expr));"
        return try await withCheckedThrowingContinuation { cont in
            webView.callAsyncJavaScript(
                body, arguments: [:], in: nil, in: .page
            ) { result in
                switch result {
                case .failure(let e): cont.resume(throwing: e)
                case .success(let value):
                    if let s = value as? String {
                        cont.resume(returning: s)
                    } else {
                        cont.resume(throwing: StreamerError.decoding(
                            "bridge expected String, got \(type(of: value))"
                        ))
                    }
                }
            }
        }
    }

    /// Synchronous-bodied script (used to install the helpers themselves).
    private func evaluateVoid(_ js: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(js) { _, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: ())
            }
        }
    }

    /// Start a `WKDownload` for the given request, using the cleared session.
    /// The returned download's delegate must be set by the caller before any
    /// data arrives — `WKWebView.startDownload` invokes the delegate
    /// synchronously for `decideDestination`.
    func startDownload(_ request: URLRequest) async -> WKDownload {
        await withCheckedContinuation { cont in
            webView.startDownload(using: request) { dl in cont.resume(returning: dl) }
        }
    }

    // MARK: - Helper script

    /// Injected once on first navigation. Defines `window.__flac.*` helpers
    /// that wrap the lucida.to fetch calls and return JSON-stringified
    /// `{ok, value?, error?}` envelopes — easier to bridge than raw promises.
    private static let bridgeScript: String = #"""
    (function () {
      if (window.__flac) return;
      const enc = encodeURIComponent;
      async function call(fn) {
        try {
          const value = await fn();
          return JSON.stringify({ ok: true, value });
        } catch (e) {
          return JSON.stringify({ ok: false, error: String(e && e.message || e) });
        }
      }
      window.__flac = {
        // Returns the lucida.to assignment for an external URL — useful as a
        // ping/health check.
        ping: () => call(async () => {
          const r = await fetch('/api/load?url=' + enc('https://lucida.to/'));
          return await r.json();
        }),
        // GET /api/load?url=<inner>; returns parsed JSON.
        loadGet: (innerPath) => call(async () => {
          const r = await fetch('/api/load?url=' + enc(innerPath));
          if (!r.ok) throw new Error('loadGet HTTP ' + r.status);
          return await r.json();
        }),
        // POST /api/load?url=/api/fetch/stream/v2 with the standard body.
        // `force` (server name from a previous response) skips re-assignment.
        streamV2: (body, force) => call(async () => {
          let u = '/api/load?url=' + enc('/api/fetch/stream/v2');
          if (force) u += '&force=' + enc(force);
          const r = await fetch(u, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
          });
          if (!r.ok) throw new Error('streamV2 HTTP ' + r.status);
          return await r.json();
        }),
        // Poll a job: GET /api/load?url=/api/fetch/request/<handoff>&force=<srv>
        pollRequest: (handoff, server) => call(async () => {
          const inner = '/api/fetch/request/' + handoff;
          const u = '/api/load?url=' + enc(inner) + '&force=' + enc(server);
          const r = await fetch(u);
          if (!r.ok) throw new Error('pollRequest HTTP ' + r.status);
          return await r.json();
        }),
        // GET metadata (only used after isrc/songlink upgrades).
        metadata: (serviceURL) => call(async () => {
          const inner = '/api/fetch/metadata?url=' + enc(serviceURL);
          const r = await fetch('/api/load?url=' + enc(inner));
          if (!r.ok) throw new Error('metadata HTTP ' + r.status);
          return await r.json();
        }),
      };
    })();
    """#
}

private struct BridgeEnvelope<U: Decodable>: Decodable {
    let ok: Bool
    let value: U?
    let error: String?
}

/// Decodable that accepts any JSON shape — used when we only care whether the
/// envelope parsed as `ok: true`, not what `value` contains.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

// MARK: - Navigation delegate

extension LucidaWebController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = MainActor.assumeIsolated { webView.url?.absoluteString } ?? "?"
        Task { @MainActor in
            self.addLog(.nav, "didFinish \(url)")
            do {
                // Install the bridge unconditionally — it only defines
                // `window.__flac` helpers, no network. Safe on the CF
                // interstitial; gives us a way to silently probe the API.
                try await self.evaluateVoid(Self.bridgeScript)

                let cfDetected = try await self.isCloudflareChallenge()

                if cfDetected {
                    // Functional probe: even with a CF banner present, if
                    // `/api/load` actually returns JSON the bridge can do
                    // its job — don't bother the user with a sheet.
                    if await self.bridgePingSucceeds() {
                        self.addLog(.info, "cf markers present but bridge ping ok; treating as ready")
                        self.phase = .ready
                        self.needsUserChallenge = false
                        self.addLog(.ok, "bridge installed; ready")
                        self.resolveWaiters(.success(()))
                        return
                    }

                    if self.hasPromptedThisSession {
                        // Already showed the sheet once this session; don't
                        // re-prompt. Leave `phase = .loading` so callers'
                        // `awaitReady()` surfaces as a normal failure rather
                        // than as a popup.
                        self.addLog(.info, "cloudflare reappeared; suppressing repeat prompt this session")
                        return
                    }
                    self.addLog(.info, "cloudflare challenge detected; awaiting clearance")
                    self.hasPromptedThisSession = true
                    self.needsUserChallenge = true
                    return
                }

                self.phase = .ready
                self.needsUserChallenge = false
                self.addLog(.ok, "bridge installed; ready")
                self.resolveWaiters(.success(()))
            } catch {
                let msg = (error as NSError).localizedDescription
                self.phase = .failed(msg)
                self.addLog(.error, "bridge install failed: \(msg)")
                self.resolveWaiters(.failure(StreamerError.unavailable("Lucida bridge install failed: \(msg)")))
            }
        }
    }

    /// Silent functional probe: call `window.__flac.ping()` directly (bypassing
    /// `callBridge`/`awaitReady` so we can run it before `phase = .ready`) and
    /// return true iff the envelope parses with `ok: true`. Used to decide
    /// whether a CF interstitial is actually blocking the API.
    private func bridgePingSucceeds() async -> Bool {
        do {
            let str = try await evaluateString("window.__flac && window.__flac.ping()")
            guard let data = str.data(using: .utf8) else { return false }
            let env = try JSONDecoder().decode(BridgeEnvelope<AnyDecodable>.self, from: data)
            return env.ok
        } catch {
            return false
        }
    }

    /// Heuristic check for a Cloudflare "Just a moment..." / managed-challenge
    /// interstitial. Matches the page title, the `#challenge-form` /
    /// `#challenge-stage` markers, and the `/cdn-cgi/challenge-platform/`
    /// script CF injects.
    private func isCloudflareChallenge() async throws -> Bool {
        let probe = #"""
        (function () {
          const t = (document.title || '').toLowerCase();
          if (t.includes('just a moment') || t.includes('attention required')) return true;
          if (document.querySelector('#challenge-form, #challenge-stage, #challenge-running')) return true;
          if (document.querySelector('script[src*="/cdn-cgi/challenge-platform/"]')) return true;
          return false;
        })()
        """#
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            webView.evaluateJavaScript(probe) { value, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (value as? Bool) ?? false)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.recordNavFailure("didFail", error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.recordNavFailure("didFailProvisional", error) }
    }

    private func recordNavFailure(_ stage: String, _ error: Error) {
        let ns = error as NSError
        let detail = "\(stage) [\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
        addLog(.error, detail)
        phase = .failed(ns.localizedDescription)
        resolveWaiters(.failure(error))
    }
}

// MARK: - UI delegate

extension LucidaWebController: WKUIDelegate {
    /// lucida.to's own frontend hands completed downloads off via
    /// `window.open(url)` (see `LucidaWebProvider.getStream`). We have exactly
    /// one `WKWebView`, shared by every bridge call and re-parented into the
    /// debug pane / challenge sheet — with no `uiDelegate`, WebKit's default
    /// for a new-window request is to navigate the *existing* view in place,
    /// stranding it on whatever CDN/redirect target the popup pointed at.
    /// From then on every relative-path `fetch('/api/load?...')` in the
    /// bridge script resolves against the wrong origin and fails instantly
    /// with "Failed to fetch". Returning `nil` here tells WebKit there's no
    /// new window to hand the request to, so it's dropped instead of
    /// hijacking the main frame — lucida.to stays the current page no matter
    /// what the user clicks while poking at the real site (e.g. in the debug
    /// pane).
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        Task { @MainActor in
            self.addLog(.info, "swallowed window.open: \(navigationAction.request.url?.absoluteString ?? "?")")
        }
        return nil
    }
}

// MARK: - Hidden window host

extension LucidaWebController {
    /// WKWebView only ticks JS reliably when attached to a window. We park it
    /// in a 1×1 transparent off-screen window — invisible, never key, no menu
    /// bar entry, just enough AppKit context to make the runtime happy.
    private static var hiddenHosts: [WKWebView: NSWindow] = [:]

    static func host(_ webView: WKWebView) {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .normal
        window.contentView?.addSubview(webView)
        window.orderOut(nil)
        hiddenHosts[webView] = window
    }
}
