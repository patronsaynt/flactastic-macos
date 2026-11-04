import SwiftUI
import AppKit

// MARK: - Model

/// Item model for `.flContextMenu { ... }`. Kept as a value type so menus can
/// be built from a result builder and passed into the AppKit popup window.
enum FLContextMenuItem: Identifiable {
    case button(id: UUID, title: String, systemImage: String?, isDestructive: Bool, action: () -> Void)
    case divider(id: UUID)
    case submenu(id: UUID, title: String, systemImage: String?, items: [FLContextMenuItem])
    case label(id: UUID, title: String)
    /// Inline text field. Submitting (Return) calls `onSubmit` with the
    /// trimmed text and dismisses the menu. Empty submissions are ignored.
    case textField(id: UUID, placeholder: String, systemImage: String?, onSubmit: (String) -> Void)

    var id: UUID {
        switch self {
        case .button(let id, _, _, _, _): return id
        case .divider(let id): return id
        case .submenu(let id, _, _, _): return id
        case .label(let id, _): return id
        case .textField(let id, _, _, _): return id
        }
    }

    static func button(_ title: String,
                       systemImage: String? = nil,
                       destructive: Bool = false,
                       action: @escaping () -> Void) -> FLContextMenuItem {
        .button(id: UUID(), title: title, systemImage: systemImage, isDestructive: destructive, action: action)
    }

    static var divider: FLContextMenuItem { .divider(id: UUID()) }

    static func submenu(_ title: String,
                        systemImage: String? = nil,
                        items: [FLContextMenuItem]) -> FLContextMenuItem {
        .submenu(id: UUID(), title: title, systemImage: systemImage, items: items)
    }

    static func label(_ title: String) -> FLContextMenuItem {
        .label(id: UUID(), title: title)
    }

    static func textField(
        _ placeholder: String,
        systemImage: String? = nil,
        onSubmit: @escaping (String) -> Void
    ) -> FLContextMenuItem {
        .textField(id: UUID(), placeholder: placeholder, systemImage: systemImage, onSubmit: onSubmit)
    }
}

// MARK: - Result Builder

@resultBuilder
enum FLContextMenuBuilder {
    static func buildExpression(_ e: FLContextMenuItem) -> [FLContextMenuItem] { [e] }
    static func buildExpression(_ e: [FLContextMenuItem]) -> [FLContextMenuItem] { e }
    static func buildBlock(_ parts: [FLContextMenuItem]...) -> [FLContextMenuItem] { parts.flatMap { $0 } }
    static func buildOptional(_ c: [FLContextMenuItem]?) -> [FLContextMenuItem] { c ?? [] }
    static func buildEither(first c: [FLContextMenuItem]) -> [FLContextMenuItem] { c }
    static func buildEither(second c: [FLContextMenuItem]) -> [FLContextMenuItem] { c }
    static func buildArray(_ parts: [[FLContextMenuItem]]) -> [FLContextMenuItem] { parts.flatMap { $0 } }
}

// MARK: - Controller

/// Tracks the open root/submenu pair so hover interactions can dismiss the
/// correct window and clicks close the whole tower at once.
@MainActor
final class FLContextMenuController {
    static let shared = FLContextMenuController()

    // Held strongly: a menu window the controller loses track of can't be
    // dismissed by anything and stays on screen for good.
    var rootWindow: FLContextMenuWindow?
    var childWindow: FLContextMenuWindow?

    // MARK: Choosing which menu a right-click opens

    /// Every right-click catcher on screen, and the one monitor that serves
    /// them all. A right-click asks each whether it's under the pointer and
    /// visible, then opens only the one that belongs to what's actually there
    /// (see `pick`), so the menu never depends on which listener ran first.
    private let catchers = NSHashTable<FLRightClickTarget>.weakObjects()
    private var monitor: Any?

    func register(_ catcher: FLRightClickTarget) {
        catchers.add(catcher)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            MainActor.assumeIsolated { FLContextMenuController.shared.route(event) } ? nil : event
        }
    }

    func unregister(_ catcher: FLRightClickTarget) { catchers.remove(catcher) }

    /// Opens the right menu for this click; false if no menu claims it.
    private func route(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let point = event.locationInWindow
        let candidates = catchers.allObjects.filter { $0.window === window && $0.isUnder(point) }
        guard let chosen = Self.pick(candidates, at: point) else { return false }
        let items = chosen.items()
        guard !items.isEmpty else { return false }
        let screenPoint = NSEvent.mouseLocation
        Task { @MainActor in FLContextMenuWindow.present(items: items, at: screenPoint) }
        return true
    }

    /// The menu for what's really under the pointer:
    /// 1. the highest `priority` (panels floating over the page, like the queue);
    /// 2. the frontmost, so a page drawn over another (a mix page over Home)
    ///    wins over what's hidden beneath it;
    /// 3. then the innermost menu nested inside that one (a track row's menu
    ///    rather than its list's), repeatedly.
    static func pick(_ candidates: [FLRightClickTarget], at point: NSPoint) -> FLRightClickTarget? {
        guard let top = candidates.map(\.menuPriority).max() else { return nil }
        let ranked = candidates.filter { $0.menuPriority == top }
            .sorted { isInFront($0, of: $1) }
        guard var best = ranked.first else { return nil }
        while let inner = ranked.first(where: { $0 !== best && encloses(best, $0) }) {
            best = inner
        }
        return best
    }

    private static func frameInWindow(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }

    /// `outer` fully contains `inner`, and is strictly bigger.
    private static func encloses(_ outer: NSView, _ inner: NSView) -> Bool {
        let o = frameInWindow(outer).insetBy(dx: -0.5, dy: -0.5), i = frameInWindow(inner)
        return o.contains(i) && i.width * i.height < o.width * o.height - 1
    }

    /// Drawing order: a view later among its siblings (or a descendant of
    /// one) is drawn over an earlier one.
    static func isInFront(_ a: NSView, of b: NSView) -> Bool {
        func path(_ v: NSView) -> [Int] {
            var out: [Int] = []
            var node = v
            while let parent = node.superview {
                out.append(parent.subviews.firstIndex(of: node) ?? 0)
                node = parent
            }
            return out.reversed()
        }
        let pa = path(a), pb = path(b)
        for (x, y) in zip(pa, pb) where x != y { return x > y }
        return pa.count > pb.count
    }

    func dismissAll() {
        childWindow?.closeImmediately()
        rootWindow?.closeImmediately()
        childWindow = nil
        rootWindow = nil
    }

    func dismissChild() {
        childWindow?.closeImmediately()
        childWindow = nil
    }
}

// MARK: - Menu View

struct FLContextMenuView: View {
    let items: [FLContextMenuItem]
    let isSubmenu: Bool
    let onCommit: () -> Void

    @State private var hoveredID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
        .onHover { hovering in
            if hovering, !isSubmenu {
                // Mouse moved over the root menu (not on a submenu row) —
                // collapse any open submenu.
                let hoverIsOnSubmenuRow = items.contains { item in
                    if case .submenu = item, item.id == hoveredID { return true }
                    return false
                }
                if !hoverIsOnSubmenuRow {
                    FLContextMenuController.shared.dismissChild()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: FLContextMenuItem) -> some View {
        switch item {
        case .button(_, let title, let systemImage, let destructive, let action):
            FLMenuRow(
                title: title,
                systemImage: systemImage,
                trailingChevron: false,
                isDestructive: destructive,
                isHovered: hoveredID == item.id,
                onHover: { hovering in
                    if hovering {
                        hoveredID = item.id
                        // Only the root menu closes an open submenu on hover;
                        // hovering rows inside the submenu itself must not
                        // dismiss the submenu (that would close it the moment
                        // the cursor enters).
                        if !isSubmenu {
                            FLContextMenuController.shared.dismissChild()
                        }
                    } else if hoveredID == item.id {
                        hoveredID = nil
                    }
                },
                onTap: {
                    // Close the menus before acting: the action often
                    // navigates, and the re-layout it causes fires late hover
                    // callbacks on rows that are still on screen.
                    onCommit()
                    action()
                }
            )
        case .divider:
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        case .submenu(_, let title, let systemImage, let children):
            SubmenuRow(
                title: title,
                systemImage: systemImage,
                children: children,
                isHovered: hoveredID == item.id,
                onHover: { hovering, rect in
                    if hovering {
                        hoveredID = item.id
                        FLContextMenuWindow.presentChild(items: children, anchor: rect, onCommit: onCommit)
                    } else if hoveredID == item.id {
                        hoveredID = nil
                    }
                }
            )
        case .label(_, let title):
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        case .textField(_, let placeholder, let systemImage, let onSubmit):
            FLMenuTextFieldRow(
                placeholder: placeholder,
                systemImage: systemImage,
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onCommit()
                    onSubmit(trimmed)
                }
            )
        }
    }
}

private struct FLMenuTextFieldRow: View {
    let placeholder: String
    let systemImage: String?
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let icon = systemImage {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Spacer().frame(width: 16)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { onSubmit(text) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.surfaceHover.opacity(0.5))
                .padding(.horizontal, 4)
        )
        .onAppear {
            // Defer one runloop tick so the hosting window has finished
            // becoming key before we ask for focus.
            DispatchQueue.main.async { focused = true }
        }
    }
}

// MARK: - Individual Row

private struct FLMenuRow: View {
    let title: String
    let systemImage: String?
    let trailingChevron: Bool
    let isDestructive: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let icon = systemImage {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
            } else {
                Spacer().frame(width: 16)
            }
            Text(title)
                .font(Theme.Font.body)
                .lineLimit(1)
            Spacer(minLength: 16)
            if trailingChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .foregroundStyle(
            isDestructive
                ? Color(red: 0.95, green: 0.35, blue: 0.35)
                : Theme.textPrimary
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isHovered ? Theme.surfaceHover : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover(perform: onHover)
        .onTapGesture { onTap() }
    }
}

private struct SubmenuRow: View {
    let title: String
    let systemImage: String?
    let children: [FLContextMenuItem]
    let isHovered: Bool
    let onHover: (Bool, NSRect) -> Void

    @State private var rowScreenFrame: NSRect = .zero

    var body: some View {
        FLMenuRow(
            title: title,
            systemImage: systemImage,
            trailingChevron: true,
            isDestructive: false,
            isHovered: isHovered,
            onHover: { hovering in
                onHover(hovering, FLContextMenuWindow.submenuAnchor(rowScreenFrame: rowScreenFrame))
            },
            onTap: {
                onHover(true, FLContextMenuWindow.submenuAnchor(rowScreenFrame: rowScreenFrame))
            }
        )
        .background(RowFrameReporter { rowScreenFrame = $0 })
    }
}

/// Reports the view's frame in screen coordinates via AppKit, bypassing
/// SwiftUI coordinate space ambiguities entirely.
private struct RowFrameReporter: NSViewRepresentable {
    let onFrame: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let frameInScreen = window.convertToScreen(nsView.convert(nsView.bounds, to: nil))
            onFrame(frameInScreen)
        }
    }
}

// MARK: - Window

/// Borderless panel that hosts the SwiftUI menu view. Uses a global mouse-down
/// monitor to dismiss when the user clicks anywhere else.
final class FLContextMenuWindow: NSPanel {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isChild: Bool = false

    static func present(items: [FLContextMenuItem], at screenPoint: NSPoint) {
        FLContextMenuController.shared.dismissAll()
        let window = FLContextMenuWindow()
        window.configure(items: items, at: screenPoint, isChild: false)
        FLContextMenuController.shared.rootWindow = window
        window.orderFrontRegardless()
        window.makeKey()
    }

    static func presentChild(items: [FLContextMenuItem], anchor: NSRect, onCommit: @escaping () -> Void) {
        // Only under a live root menu. A hover callback from a row of a menu
        // that's just been dismissed (by clicking an item that navigated)
        // otherwise opened a submenu with no root behind it, which nothing
        // would ever close.
        guard let root = FLContextMenuController.shared.rootWindow, root.isVisible else { return }
        FLContextMenuController.shared.dismissChild()
        let window = FLContextMenuWindow()
        window.configureChild(items: items, anchor: anchor, onCommit: onCommit)
        FLContextMenuController.shared.childWindow = window
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Anchor for a submenu: right edge of the root menu, aligned to the
    /// parent row's top edge in screen coordinates. `rowScreenFrame` is the
    /// NSRect of the SubmenuRow in screen coords, reported directly by AppKit.
    static func submenuAnchor(rowScreenFrame: NSRect) -> NSRect {
        guard let root = FLContextMenuController.shared.rootWindow else {
            return NSRect(origin: NSEvent.mouseLocation, size: .zero)
        }
        // rowScreenFrame.maxY is the top edge of the row (NSRect Y-up origin).
        // Subtract 4pt (menu's outer vertical padding) so the first child row
        // aligns with the parent row.
        return NSRect(x: root.frame.maxX, y: rowScreenFrame.maxY - 4, width: 0, height: 0)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.hasShadow = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func configure(items: [FLContextMenuItem], at screenPoint: NSPoint, isChild: Bool) {
        self.isChild = isChild
        let view = FLContextMenuView(items: items, isSubmenu: isChild) { [weak self] in
            FLContextMenuController.shared.dismissAll()
            _ = self
        }
        installHosting(view: AnyView(view), origin: screenPoint, anchorRight: false)
        installDismissMonitors()
    }

    func configureChild(items: [FLContextMenuItem], anchor: NSRect, onCommit: @escaping () -> Void) {
        self.isChild = true
        let view = FLContextMenuView(items: items, isSubmenu: true) {
            onCommit()
            FLContextMenuController.shared.dismissAll()
        }
        // anchor.origin.y is the desired top edge of the submenu window in
        // screen coords; `installHosting` subtracts height to convert this
        // top edge into an AppKit bottom-left origin.
        let origin = NSPoint(x: anchor.origin.x + 2, y: anchor.origin.y)
        installHosting(view: AnyView(view), origin: origin, anchorRight: true)
        // Its own monitors as well as the root's, so a submenu can never be
        // left on screen without something to close it.
        installDismissMonitors()
    }

    private func installHosting(view: AnyView, origin: NSPoint, anchorRight: Bool) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // Force layout so fittingSize is accurate.
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = NSSize(
            width: max(fitting.width, 220),
            height: max(fitting.height, 32)
        )

        var finalOrigin = origin
        // Default: drop menu down-right from the cursor.
        if !anchorRight {
            finalOrigin.y -= size.height
        } else {
            finalOrigin.y -= size.height
        }
        // Keep within screen bounds.
        let screen = NSScreen.screens.first(where: { NSMouseInRect(origin, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if finalOrigin.x + size.width > visible.maxX {
                finalOrigin.x = max(visible.minX + 4, visible.maxX - size.width - 4)
            }
            if finalOrigin.x < visible.minX { finalOrigin.x = visible.minX + 4 }
            if finalOrigin.y < visible.minY { finalOrigin.y = visible.minY + 4 }
            if finalOrigin.y + size.height > visible.maxY {
                finalOrigin.y = visible.maxY - size.height - 4
            }
        }

        let rect = NSRect(origin: finalOrigin, size: size)
        self.setFrame(rect, display: false)
        self.contentView = hostingView
    }

    private var resignObserver: NSObjectProtocol?

    private func installDismissMonitors() {
        // Switching to another app closes menus, as native ones do.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { FLContextMenuController.shared.dismissAll() }
        }
        // Fires only for events in other apps.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            Task { @MainActor in
                FLContextMenuController.shared.dismissAll()
            }
        }
        // Fires for events inside our app. Dismiss when the click lands on a
        // window that isn't part of the menu tower; let clicks inside the menu
        // itself flow through so button taps can fire.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { // escape
                    Task { @MainActor in
                        FLContextMenuController.shared.dismissAll()
                    }
                    return nil
                }
                return event
            }
            let target = event.window
            let controller = FLContextMenuController.shared
            let isMenu = (target === controller.rootWindow) || (target === controller.childWindow)
            // Clicks, and scrolling the page underneath, close the menu; it
            // would otherwise float over content that's moved out from under it.
            if !isMenu {
                Task { @MainActor in
                    FLContextMenuController.shared.dismissAll()
                }
            }
            return event
        }
    }

    func closeImmediately() {
        if let gm = globalMonitor {
            NSEvent.removeMonitor(gm)
            globalMonitor = nil
        }
        if let lm = localMonitor {
            NSEvent.removeMonitor(lm)
            localMonitor = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        self.orderOut(nil)
    }
}

// MARK: - Right-Click Catcher

extension View {
    /// Shows a themed custom context menu on right-click. Items are built with
    /// `FLContextMenuBuilder` — mirrors SwiftUI's `.contextMenu` but renders
    /// the app's monochrome style.
    ///
    /// `priority` controls which menu wins when multiple overlapping catchers
    /// (e.g. a floating panel over the main content) all receive the same
    /// right-click. Higher value wins; default is 0.
    func flContextMenu(priority: Int = 0, @FLContextMenuBuilder items: @escaping () -> [FLContextMenuItem]) -> some View {
        self.overlay(FLRightClickCatcher(itemsProvider: items, priority: priority))
    }
}

private struct FLRightClickCatcher: NSViewRepresentable {
    let itemsProvider: () -> [FLContextMenuItem]
    var priority: Int = 0

    func makeNSView(context: Context) -> RightClickView {
        let v = RightClickView()
        v.itemsProvider = itemsProvider
        v.menuPriority = priority
        return v
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.itemsProvider = itemsProvider
        nsView.menuPriority = priority
    }

    /// Zero-interference right-click catcher. The view is fully transparent to
    /// `hitTest` (always returns `nil`), so it never participates in AppKit's
    /// mouse-event routing — this is critical inside `List` rows, where any
    /// NSView overlay that could be hit-tested breaks the table's drag-to-
    /// reorder machinery. Right-clicks are instead picked up via a local
    /// NSEvent monitor that checks whether the click falls inside our bounds.
    final class RightClickView: FLRightClickTarget {}
}

/// An invisible stand-in for one `.flContextMenu`. Never takes part in
/// hit-testing (always returns nil), which matters inside `List` rows, where
/// any overlay that can be hit breaks drag-to-reorder. Right-clicks reach it
/// through `FLContextMenuController`, which decides which menu opens.
class FLRightClickTarget: NSView {
    var itemsProvider: (() -> [FLContextMenuItem])?
    var menuPriority: Int = 0

    func items() -> [FLContextMenuItem] { itemsProvider?() ?? [] }

    /// Under the pointer and actually showing there: in a window, not
    /// hidden, and not scrolled or clipped out of view.
    func isUnder(_ windowPoint: NSPoint) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, alphaValue > 0 else { return false }
        let p = convert(windowPoint, from: nil)
        return bounds.contains(p) && visibleRect.contains(p)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            FLContextMenuController.shared.register(self)
        } else {
            FLContextMenuController.shared.unregister(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }
}
