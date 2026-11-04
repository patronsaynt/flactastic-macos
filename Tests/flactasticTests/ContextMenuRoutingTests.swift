import AppKit
import SwiftUI
import Testing
@testable import flactastic

/// Which `.flContextMenu` a right-click opens, in a real SwiftUI window.
@MainActor
struct ContextMenuRoutingTests {
    private func targets(in view: NSView) -> [FLRightClickTarget] {
        ((view as? FLRightClickTarget).map { [$0] } ?? []) + view.subviews.flatMap { targets(in: $0) }
    }

    private func host<V: View>(_ content: V) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: content.frame(width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func menuTitle(at point: NSPoint, in root: NSView) -> String? {
        let all = targets(in: root).filter { $0.isUnder(point) }
        guard let chosen = FLContextMenuController.pick(all, at: point) else { return nil }
        if case .button(_, let title, _, _, _) = chosen.items().first { return title }
        return nil
    }

    @Test func pageDrawnOverAnotherWins() {
        let (window, root) = host(
            ZStack {
                Color.gray.frame(width: 400, height: 300).flContextMenu { FLContextMenuItem.button("Under") {} }
                Color.white.frame(width: 400, height: 300)
                    .overlay(alignment: .top) {
                        Color.blue.frame(height: 40).flContextMenu { FLContextMenuItem.button("Row") {} }
                    }
            }
        )
        _ = window
        // Both menus really are under that point; only the front one opens.
        #expect(targets(in: root).filter { $0.isUnder(NSPoint(x: 200, y: 280)) }.count == 2)
        // Top strip: the row on the page in front, never the page beneath.
        #expect(menuTitle(at: NSPoint(x: 200, y: 280), in: root) == "Row")
        #expect(menuTitle(at: NSPoint(x: 20, y: 280), in: root) == "Row")
    }

    @Test func innermostMenuWinsOverItsContainer() {
        let (window, root) = host(
            VStack(spacing: 0) {
                Color.blue.frame(height: 40).flContextMenu { FLContextMenuItem.button("Row") {} }
                Color.clear
            }
            .flContextMenu { FLContextMenuItem.button("List") {} }
        )
        _ = window
        #expect(menuTitle(at: NSPoint(x: 350, y: 280), in: root) == "Row")
        #expect(menuTitle(at: NSPoint(x: 200, y: 100), in: root) == "List")
    }

    @Test func scrolledOutOfViewDoesNotCount() {
        let (window, root) = host(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<20) { i in
                        Color.blue.frame(height: 100).flContextMenu { FLContextMenuItem.button("Row \(i)") {} }
                    }
                }
            }
        )
        _ = window
        // Only the rows actually on screen are candidates.
        #expect(menuTitle(at: NSPoint(x: 200, y: 250), in: root) == "Row 0")
    }
}
