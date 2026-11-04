import SwiftUI
import AppKit

extension EnvironmentValues {
    /// How far the floating top bar reaches down over the page. Pages run
    /// to the top of the window and keep anything that must stay clear of
    /// the bar (titles, back buttons) this far down; 0 when the bar is
    /// hidden (fullscreen Visualizer).
    @Entry var topBarInset: CGFloat = 0
}

/// The window's top bar: a frosted rail that floats over the page, beside
/// the traffic lights. It holds the FLACtastic menu (Settings, Devices,
/// importing, refresh, About), then the tabs as words, the library tabs and
/// the tools split by a hairline, the current one underlined. Pages scroll
/// beneath it; the empty strip around it still drags the window.
struct TopBarView: View {
    @Binding var selectedTab: AppTab

    @Environment(Settings.self) private var settings
    @Environment(NavigationRouter.self) private var router
    @Environment(ImportCoordinator.self) private var importCoordinator
    @Environment(LibraryStore.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var underline

    /// The strip the rail floats in; pages are inset by this much.
    static let height: CGFloat = 58
    /// Clears the traffic lights (moved in by `TitleBarConfigurator`).
    private static let leadingInset: CGFloat = 84

    private let libraryTabs: [AppTab] = [.home, .collection, .playlists]

    private var toolTabs: [AppTab] {
        [.download, .organizer, .visualizer].filter { $0 != .download || settings.showDownloadTab }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.leadingInset)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(WindowDragArea())     // empty areas drag the window
    }

    private var rail: some View {
        HStack(spacing: 0) {
            AppMenuButton(items: menuItems)
                .padding(.trailing, 4)

            ForEach(libraryTabs) { tabButton($0) }

            Rectangle()
                .fill(Theme.textPrimary.opacity(0.16))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 8)

            ForEach(toolTabs) { tabButton($0) }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(glassTint))
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(colorScheme == .light ? 0.08 : 0.1), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .light ? 0.12 : 0.3), radius: 14, y: 6)
        }
    }

    private var glassTint: Color {
        colorScheme == .light ? Color(white: 0.98).opacity(0.55) : Color(white: 0.09).opacity(0.5)
    }

    private func tabButton(_ tab: AppTab) -> some View {
        TopBarTab(
            title: tab.rawValue,
            isSelected: selectedTab == tab,
            underline: underline
        ) {
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.3)) {
                selectedTab = tab
            }
        }
    }

    private var menuItems: [FLContextMenuItem] {
        [
            .button("Settings…", systemImage: "gearshape") { router.showSettings = true },
            .button("UI for Nerds…", systemImage: "slider.horizontal.3") { openWindow(id: "ui-for-nerds") },
            .button("Devices…", systemImage: "laptopcomputer.and.iphone") { openWindow(id: "sync") },
            .divider,
            .button("Import Track…", systemImage: "music.note") { importCoordinator.begin(.track) },
            .button("Import Album…", systemImage: "square.stack") { importCoordinator.begin(.album) },
            .button("Import Files as Playlist…", systemImage: "list.bullet.rectangle") { importCoordinator.begin(.playlist) },
            .divider,
            .button("Refresh Library", systemImage: "arrow.clockwise") { library.refreshLibrary() },
            .button("About FLACtastic", systemImage: "info.circle") { openWindow(id: "about") },
        ]
    }
}

/// One tab, as a word. The current one is bright with an underline that
/// slides between tabs.
private struct TopBarTab: View {
    let title: String
    let isSelected: Bool
    let underline: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(isSelected || isHovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    if isHovering && !isSelected {
                        Capsule().fill(Theme.textPrimary.opacity(0.08))
                    }
                }
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Theme.textPrimary)
                            .frame(height: 2)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(BarPressButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// "FLACtastic" with a chevron: the app's menu, opened under the name.
private struct AppMenuButton: View {
    let items: [FLContextMenuItem]

    @State private var anchor = MenuAnchor()
    @State private var isHovering = false

    var body: some View {
        Button {
            anchor.present(items)
        } label: {
            HStack(spacing: 6) {
                Text("FLACtastic")
                    .font(.system(size: 14.5, weight: .heavy))
                    .tracking(-0.45)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background {
                if isHovering { Capsule().fill(Theme.textPrimary.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(BarPressButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help("Settings, Devices, Import and more")
        .accessibilityLabel("FLACtastic menu")
    }
}

/// Finds where the menu button sits on screen, so its menu opens just
/// below it rather than at the pointer.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func present(_ items: [FLContextMenuItem]) {
        guard let view, let window = view.window else {
            FLContextMenuWindow.present(items: items, at: NSEvent.mouseLocation)
            return
        }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        FLContextMenuWindow.present(items: items, at: NSPoint(x: frame.minX, y: frame.minY - 6))
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Never takes a click; it only marks the button's position.
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Reaches into the hosting `NSWindow` and configures it for a full-size,
/// transparent title bar so app content (the custom top bar) draws edge-to-edge
/// up into the title-bar region and shares the row with the traffic lights.
/// Also nudges the traffic lights inward and down so they line up vertically
/// with the pills in the custom top bar.
struct TitleBarConfigurator: NSViewRepresentable {
    /// False keeps the traffic lights hidden (behind the launch cover); true
    /// fades them in with the cover's own fade.
    var showsWindowButtons = true

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView()
        view.showsButtons = showsWindowButtons
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguratorView)?.setShowsButtons(showsWindowButtons)
    }

    private final class ConfiguratorView: NSView {
        var showsButtons = true

        private var windowButtons: [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        }

        /// Fades the traffic lights in or out over the launch cover's 0.5s ease-out.
        func setShowsButtons(_ shows: Bool) {
            guard shows != showsButtons else { return }
            showsButtons = shows
            let buttons = windowButtons
            if shows { buttons.forEach { $0.isHidden = false } }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                buttons.forEach { $0.animator().alphaValue = shows ? 1 : 0 }
            } completionHandler: { [weak self] in
                // Hidden too, so an invisible button can't be clicked.
                guard let self, !self.showsButtons else { return }
                buttons.forEach { $0.isHidden = true }
            }
        }

        /// Offsets applied to the standard window buttons. Tweak to taste:
        /// `dx` moves the group inward (right); `dy` moves it down.
        private let dx: CGFloat = 8
        private let dy: CGFloat = 14

        /// Stock height of `NSTitlebarContainerView` for a window without a
        /// toolbar. The buttons sit at a fixed distance from its bottom edge.
        private let stockTitlebarHeight: CGFloat = 28

        // The buttons can't be moved directly: on macOS 26 the title bar
        // re-lays them out at their stock origin on every layout pass (live
        // resize, frame restoration, fullscreen), undoing any `setFrameOrigin`
        // — often synchronously, before a frame-change observer can react.
        // Instead we reshape the views that contain them, which AppKit's
        // layout leaves alone: the title-bar container grows taller by `dy`
        // (the buttons keep their distance from its bottom, so they drop by
        // `dy`), and the `NSTitlebarView` inside it shifts right by `dx`.
        // Hit-testing is unaffected: clicks outside the buttons still reach
        // the content view underneath the transparent title bar.

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            configure(window)
            for button in windowButtons {
                button.alphaValue = showsButtons ? 1 : 0
                button.isHidden = !showsButtons
            }

            let center = NotificationCenter.default
            // Re-assert the custom title bar after exiting native fullscreen
            // (Big Picture mode). Fullscreen resets the style mask, which would
            // otherwise restore a real title bar and leave the content offset
            // so clicks miss their targets.
            center.addObserver(self, selector: #selector(didExitFullScreen),
                               name: NSWindow.didExitFullScreenNotification, object: window)
            // Every window resize (live, programmatic, frame restoration at
            // launch) re-lays out the title bar back to stock, so re-apply
            // after each one. Deliberately not a frame-change observer on the
            // title-bar views: that fires mid-layout, and AppKit's remaining
            // layout then overwrites the correction.
            center.addObserver(self, selector: #selector(layoutTrafficLights),
                               name: NSWindow.didResizeNotification, object: window)

            layoutTrafficLights()
            DispatchQueue.main.async { [weak self] in self?.layoutTrafficLights() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        private func configure(_ window: NSWindow) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }

        @objc private func didExitFullScreen() {
            guard let window else { return }
            configure(window)
            DispatchQueue.main.async { [weak self] in self?.layoutTrafficLights() }
        }

        private func titlebarView(in window: NSWindow) -> NSView? {
            window.standardWindowButton(.closeButton)?.superview
        }

        @objc private func layoutTrafficLights() {
            // In native fullscreen the system owns the title bar — leave it be.
            guard let window, !window.styleMask.contains(.fullScreen),
                  let titlebar = titlebarView(in: window),
                  let container = titlebar.superview,
                  let frameHeight = container.superview?.bounds.height else { return }

            let height = stockTitlebarHeight + dy
            let containerFrame = NSRect(x: container.frame.minX, y: frameHeight - height,
                                        width: container.frame.width, height: height)
            if container.frame != containerFrame {
                container.frame = containerFrame
            }
            let titlebarFrame = NSRect(x: dx, y: 0, width: containerFrame.width - dx, height: height)
            if titlebar.frame != titlebarFrame {
                titlebar.frame = titlebarFrame
            }
        }
    }
}

/// Transparent NSView that lets click-drags in empty top-bar space move the
/// window — restores the drag behaviour normally provided by the title bar.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        // The strip lies over the page, so let scrolling fall through to
        // whatever is scrolling beneath it; clicks still drag the window.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? nil : super.hitTest(point)
        }
    }
}

/// Press feedback (scale + fade) for the top bar's buttons.
struct BarPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.65),
                value: configuration.isPressed
            )
    }
}

/// Sizes the window the app opens in to fill the desktop: the screen less
/// the menu bar and Dock, as a normal window (not fullscreen). Once per
/// launch, so a window resized or opened later keeps its own size.
struct LaunchWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SizerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SizerView: NSView {
        @MainActor static var hasSized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !Self.hasSized, let window else { return }
            Self.hasSized = true
            fill(window)
            // Again after the launch pass, in case frame restoration lands later.
            DispatchQueue.main.async { [weak window] in
                if let window { Self.fill(window) }
            }
        }

        private func fill(_ window: NSWindow) { Self.fill(window) }

        private static func fill(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true)
        }
    }
}
