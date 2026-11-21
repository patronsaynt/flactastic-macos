import SwiftUI

/// A track list that works like a Mac table from the keyboard: click a row
/// (or Tab in) to focus the list, the arrow keys move between rows,
/// scrolling them into view, and Return plays the current one.
///
/// Apply it to the stack inside the list's scroll view. Each row's identity
/// must be its id in `ids`, which is how the list scrolls to it.
private struct RowKeyboardNav<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var cursor: ID?
    /// Lists with no selection of their own drop the cursor when focus
    /// leaves, so a stale highlight doesn't linger.
    let clearsOnBlur: Bool
    let play: (ID) -> Void

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable(interactions: .edit)
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.downArrow) { step(1, proxy) }
                .onKeyPress(.upArrow) { step(-1, proxy) }
                .onKeyPress(.return) {
                    guard let cursor, ids.contains(cursor) else { return .ignored }
                    play(cursor)
                    return .handled
                }
                // A click on a row moves the cursor; the list takes the keys.
                .onChange(of: cursor) { _, new in
                    if new != nil, !focused { focused = true }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, clearsOnBlur { cursor = nil }
                }
        }
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let next: Int
        if let cursor, let i = ids.firstIndex(of: cursor) {
            next = min(max(i + delta, 0), ids.count - 1)
        } else {
            next = delta > 0 ? 0 : ids.count - 1
        }
        cursor = ids[next]
        proxy.scrollTo(ids[next])
        return .handled
    }
}

extension View {
    /// Arrow keys and Return for a track list; see `RowKeyboardNav`.
    func rowKeyboardNav<ID: Hashable>(
        ids: [ID],
        cursor: Binding<ID?>,
        clearsOnBlur: Bool = false,
        play: @escaping (ID) -> Void
    ) -> some View {
        modifier(RowKeyboardNav(ids: ids, cursor: cursor, clearsOnBlur: clearsOnBlur, play: play))
    }

    /// A track row VoiceOver can play: one element, read as a button, whose
    /// default action (VO-Space) plays it.
    func playableRowAccessibility(play: @escaping () -> Void) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { play() }
    }
}
