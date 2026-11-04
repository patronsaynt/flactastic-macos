import SwiftUI

struct RiseFadeIn: ViewModifier {
    @Environment(Settings.self) private var settings
    let delay: Double
    @State private var appeared: Bool

    init(delay: Double, skipAnimation: Bool = false) {
        self.delay = delay
        // Seed straight to the settled state for cells whose entrance has
        // already played once (tracked by the parent) so a lazy container
        // recreating the cell on scroll-back doesn't replay the animation.
        self._appeared = State(initialValue: skipAnimation)
    }

    private var offsetX: CGFloat {
        guard !appeared else { return 0 }
        switch settings.fadeAnimationDirection {
        case .up: return 0
        case .leftToRight: return -10
        case .rightToLeft: return 10
        }
    }

    private var offsetY: CGFloat {
        guard !appeared else { return 0 }
        switch settings.fadeAnimationDirection {
        case .up: return 10
        case .leftToRight, .rightToLeft: return 0
        }
    }

    func body(content: Content) -> some View {
        if !settings.fadeAnimationsEnabled {
            content
        } else {
            content
                .opacity(appeared ? 1 : 0)
                .offset(x: offsetX, y: offsetY)
                .onAppear {
                    guard !appeared else { return }
                    withAnimation(.easeOut(duration: 0.28).delay(delay)) {
                        appeared = true
                    }
                }
        }
    }
}

extension View {
    func riseFadeIn(delay: Double = 0) -> some View {
        modifier(RiseFadeIn(delay: delay))
    }

    func riseFadeIn(index: Int, step: Double = 0.015, max: Double = 0.25) -> some View {
        modifier(RiseFadeIn(delay: Swift.min(Double(index) * step, max)))
    }

    /// Like `riseFadeIn(index:)`, but skips replaying the entrance animation
    /// for items that have already animated in once. Lazy grids/stacks
    /// discard a cell's `@State` when it scrolls far enough off-screen, so
    /// without this, scrolling back to a previously-seen item would replay
    /// its fade-in — `animatedIDs` should be owned by something that
    /// outlives the calling view's own lifecycle (not local `@State`), since
    /// `ContentView` remounts each tab's content on every switch.
    ///
    /// `enabled` additionally gates the *entire initial burst*: when a grid
    /// first populates, dozens of cells can call this within the same
    /// render pass, each scheduling its own `withAnimation` — animating
    /// that many cells simultaneously is itself a source of stutter,
    /// independent of which ones have been seen before. Pass `enabled:
    /// false` for that first synchronous pass (e.g. via a `@State` that
    /// starts `false` and flips `true` in a `.task` shortly after the view
    /// appears) so the bulk reveal renders instantly; anything that shows up
    /// afterward (search results, continued scrolling) still animates.
    func riseFadeIn<ID: Hashable>(
        index: Int,
        animated id: ID,
        animatedIDs: Binding<Set<ID>>,
        enabled: Bool = true,
        step: Double = 0.015,
        max: Double = 0.25
    ) -> some View {
        let alreadyAnimated = animatedIDs.wrappedValue.contains(id)
        let skip = !enabled || alreadyAnimated
        return self
            .modifier(RiseFadeIn(
                delay: Swift.min(Double(index) * step, max),
                skipAnimation: skip
            ))
            .onAppear {
                if !alreadyAnimated { animatedIDs.wrappedValue.insert(id) }
            }
    }
}

extension View {
    /// Fades and lifts into place when `active` flips, after a page's
    /// entrance zoom (album, artist and playlist pages).
    func arrival(_ active: Bool, calm: Bool, animation: Animation) -> some View {
        self
            .opacity(active ? 1 : 0)
            .offset(y: active || calm ? 0 : 16)
            .animation(calm ? .easeOut(duration: 0.3) : animation, value: active)
    }
}
