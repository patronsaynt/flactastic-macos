import AppKit
import SwiftUI

/// Reports every pointer move inside its window, in its own top-left
/// coordinates, through a local event monitor. Takes no clicks itself.
///
/// Use instead of `onHover` / `onContinuousHover` where hover must keep
/// working after the view is torn down and rebuilt mid-transition: SwiftUI's
/// hover tracking areas can go stale then and stop reporting until the
/// pointer leaves and re-enters the window. A window-level monitor can't.
struct PointerWatcher: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    /// The pointer left this view's area — including straight out of the
    /// window, where no further moves arrive to say so.
    var onExit: (() -> Void)? = nil

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onMove = onMove
        view.onExit = onExit
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stop()
    }

    final class WatcherView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            // Without this the window only delivers moves inside tracking
            // areas, which is the very thing that went stale.
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                self.onMove?(self.convert(event.locationInWindow, from: nil))
                return event
            }
        }

        // An AppKit-owned tracking area, rebuilt by AppKit on every layout
        // change, used only to notice the pointer leaving.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
