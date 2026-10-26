import SwiftUI
import WebKit

/// Debug pane for the Lucida WebKit bridge. Toggled from
/// View → "Enable Debugging".
///
/// Shows: current phase, the live `WKWebView` (re-parented from its hidden
/// host while this window is on screen), and an append-only log of
/// navigations / bridge calls / errors. Right-click → Inspect Element opens
/// Web Inspector when running on macOS 13.3+.
struct LucidaDebugView: View {
    @Environment(LucidaWebController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Phase:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(phaseLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(phaseColor)
                Spacer()
                Button("Reload") { controller.reload() }
                Button("Clear Site Data") { controller.clearSiteData() }
                Button("Clear log") { controller.clearLog() }
            }
            .padding(8)
            .background(.bar)

            HSplitView {
                LucidaWebHost(webView: controller.webView)
                    .frame(minWidth: 480)

                LogListView(entries: controller.log)
                    .frame(minWidth: 320)
            }
        }
    }

    private var phaseLabel: String {
        switch controller.phase {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed(let m): return "failed — \(m)"
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .idle, .loading: return .secondary
        case .ready: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Log list

private struct LogListView: View {
    let entries: [LucidaWebController.LogEntry]
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.timeFmt.string(from: e.timestamp))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(e.kind.rawValue)
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .foregroundStyle(color(for: e.kind))
                                .frame(width: 48, alignment: .leading)
                            Text(e.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .id(e.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(for kind: LucidaWebController.LogEntry.Kind) -> Color {
        switch kind {
        case .nav:    return .blue
        case .bridge: return .purple
        case .ok:     return .green
        case .error:  return .red
        case .info:   return .secondary
        }
    }
}

// MARK: - Open/close on toggle

/// Invisible bridge between Settings → Debug → "Lucida inspector" and the
/// `Window(id: "lucida-debug")` scene. Calling `openWindow` / `dismissWindow`
/// has to happen from a SwiftUI view, so we park this zero-sized view in
/// the main window and react to the switch.
struct DebugWindowController: View {
    let enabled: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { sync(enabled) }
            .onChange(of: enabled) { _, newValue in sync(newValue) }
    }

    private func sync(_ open: Bool) {
        if open { openWindow(id: "lucida-debug") }
        else    { dismissWindow(id: "lucida-debug") }
    }
}

// MARK: - WebView re-parenting host

/// Wraps `controller.webView` for SwiftUI. The same `WKWebView` instance is
/// the one driving the JS bridge — we only have one — so the debug window
/// re-parents it onto its container, and we don't pin it back when the
/// window closes (the hidden NSWindow it lived in originally is still
/// retaining it via its content view, which keeps the WebView alive even
/// after our SwiftUI host releases it).
struct LucidaWebHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Re-parenting a live WKWebView into a new window's view hierarchy
        // leaves the page running (JS keeps ticking — bridge calls still
        // complete) but WebKit's remote layer-hosting connection stays bound
        // to the old window, so nothing actually paints: the pane renders
        // blank/gray. Toggling `isHidden` on the next run-loop turn forces
        // WebKit to rebuild that connection against the window it's in now.
        DispatchQueue.main.async {
            webView.isHidden = true
            webView.isHidden = false
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
