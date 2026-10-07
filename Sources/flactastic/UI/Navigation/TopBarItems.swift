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
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        /// Offsets applied to the standard window buttons. Tweak to taste:
        /// `dx` moves the group inward (right); `dy` moves it down (AppKit's
        /// y-axis points up, so a negative value moves the lights downward).
        private let dx: CGFloat = 8
        private let dy: CGFloat = -14

        private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        /// Each button's stock origin within its superview (`NSTitlebarView`),
        /// captured once. This is a fixed OS constant — confirmed by logging
        /// it across launch-time window-frame restoration and manual resizes,
        /// it never moves — so the target position can always be recomputed
        /// from it directly, without ever reading the button's current (and
        /// possibly already-nudged) frame as if it were a fresh baseline.
        /// That keeps every reposition idempotent no matter what triggers it.
        private var stockOrigins: [NSWindow.ButtonType: CGPoint] = [:]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configure(window)
            captureStockOrigins(in: window)

            // Re-assert the custom title bar after exiting native fullscreen
            // (Big Picture mode). Fullscreen resets the style mask, which would
            // otherwise restore a real title bar and leave the content offset
            // so clicks miss their targets.
            NotificationCenter.default.addObserver(
                self, selector: #selector(didExitFullScreen),
                name: NSWindow.didExitFullScreenNotification, object: window
            )

            // AppKit re-lays out the standard window buttons on its own schedule
            // — window-frame restoration at launch, live resize, fullscreen
            // transitions — and any of those passes can move them. A one-shot
            // nudge therefore survives only if nothing else lays out afterwards,
            // which is exactly why the offsets held when running unbundled but
            // were lost in the packaged app (a bundled launch restores the saved
            // window frame after the content view is installed). Observing each
            // button's frame means every relayout is corrected, whoever caused
            // it — and since `reposition` recomputes the target from the fixed
            // stock origin rather than the button's own (possibly already-
            // nudged) frame, reacting to our own writes can't compound the
            // offset.
            observeButtonFrames(in: window)
            repositionTrafficLights()
            DispatchQueue.main.async { [weak self] in self?.repositionTrafficLights() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        private func configure(_ window: NSWindow) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }

        private func captureStockOrigins(in window: NSWindow) {
            guard stockOrigins.isEmpty else { return }
            for type in buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                stockOrigins[type] = button.frame.origin
            }
        }

        @objc private func didExitFullScreen() {
            guard let window else { return }
            configure(window)
            DispatchQueue.main.async { [weak self] in self?.repositionTrafficLights() }
        }

        private func observeButtonFrames(in window: NSWindow) {
            for type in buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(buttonFrameChanged(_:)),
                    name: NSView.frameDidChangeNotification, object: button
                )
            }
        }

        @objc private func buttonFrameChanged(_ note: Notification) {
            guard let button = note.object as? NSView,
                  let type = buttonTypes.first(where: { window?.standardWindowButton($0) === button })
            else { return }
            reposition(type, button: button)
        }

        @objc private func repositionTrafficLights() {
            guard let window else { return }
            for type in buttonTypes {
                guard let button = window.standardWindowButton(type) else { continue }
                reposition(type, button: button)
            }
        }

        private func reposition(_ type: NSWindow.ButtonType, button: NSView) {
            // In native fullscreen the system owns the buttons — leave them be.
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            guard let stock = stockOrigins[type] else { return }
            let target = CGPoint(x: stock.x + dx, y: stock.y + dy)
            // Already sitting where it belongs — nothing to do. This is also
            // what stops the notification we trigger below from recursing.
            guard button.frame.origin != target else { return }
            button.setFrameOrigin(target)
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

/// Circular back control for detail views. Navigation is driven manually via
/// `NavigationRouter` paths (no `NavigationStack`) because on macOS a
/// `NavigationStack` routes its back button through the window toolbar, which
/// can't coexist with the custom top bar.
struct DetailBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(BarPressButtonStyle())
    }
}

/// Press feedback (scale + fade) for the top bar's buttons and the
/// onboarding back button.
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
