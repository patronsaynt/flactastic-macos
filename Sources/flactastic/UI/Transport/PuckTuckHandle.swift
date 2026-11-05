import SwiftUI

/// A small tab flush against the window edge, on the player's side, that
/// tucks the corner player away past that edge and brings it back. Shown on
/// pages where the puck would sit over the page's own controls (Organizer).
/// Its chevron points the way the player will move.
struct PuckTuckHandle: View {
    let side: PlayerSide
    let isTucked: Bool
    let toggle: () -> Void

    static let width: CGFloat = 20
    static let height: CGFloat = 52
    static let motion = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)

    @State private var isHovering = false

    var body: some View {
        // Square against the window edge, rounded on the side facing in.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: side == .right ? 10 : 0,
            bottomLeadingRadius: side == .right ? 10 : 0,
            bottomTrailingRadius: side == .left ? 10 : 0,
            topTrailingRadius: side == .left ? 10 : 0,
            style: .continuous
        )
        Button(action: toggle) {
            VStack(spacing: 5) {
                if isTucked {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                Image(systemName: chevron)
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.textPrimary.opacity(isHovering ? 1 : 0.75))
            .frame(width: Self.width, height: Self.height)
            .background(.regularMaterial, in: shape)
            .background(Theme.textPrimary.opacity(isHovering ? 0.1 : 0.04), in: shape)
            .overlay(shape.strokeBorder(Theme.textPrimary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 8, x: side == .right ? -2 : 2, y: 3)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(Self.motion, value: isTucked)
        .help(isTucked ? "Show the player" : "Tuck the player away")
        .accessibilityLabel(isTucked ? "Show player" : "Tuck player away")
    }

    /// Toward the middle to bring the player out; toward the edge to tuck it.
    private var chevron: String {
        switch (side, isTucked) {
        case (.right, true), (.left, false): "chevron.compact.left"
        case (.right, false), (.left, true): "chevron.compact.right"
        }
    }
}
