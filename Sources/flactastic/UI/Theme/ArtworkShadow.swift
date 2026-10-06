import SwiftUI

/// Drop shadow applied to album/playlist/track artwork throughout the app.
///
/// SwiftUI's `.shadow()` renders from the composited view, so applying this
/// *after* the artwork's `.clipShape(RoundedRectangle(...))` yields a shadow
/// that follows the clipped shape — whether the user has rounded corners on
/// (pill-edge falloff) or off (hard rectangle). Black with low opacity reads
/// correctly in both light and dark modes: in dark mode it's a soft halo
/// against the deep background; in light mode it lifts the art off the gray
/// surface.
///
/// Shadow intensity scales with art size so a 36pt queue thumbnail doesn't
/// get the same bloom as a 280pt now-playing hero.
struct ArtworkShadow: ViewModifier {
    @Environment(Settings.self) private var settings
    let size: CGFloat
    var enabled: Bool = true

    private var radius: CGFloat {
        // Gentle curve: tiny thumbs ~2pt blur, hero art ~14pt.
        max(2, min(14, size * 0.06))
    }

    private var yOffset: CGFloat {
        max(1, min(6, size * 0.025))
    }

    private var opacity: Double {
        // A touch stronger on small items so the shadow is still perceptible
        // without being muddy on large art.
        size < 80 ? 0.30 : 0.22
    }

    func body(content: Content) -> some View {
        if enabled && settings.showArtworkShadow {
            // Flattening art+shadow into one rasterized layer
            // (`.drawingGroup()`) saves re-blurring during scroll compositing,
            // but each instance costs an offscreen Metal pass — worth it for
            // large art with a wide blur, a net loss for the dozens of ≤80pt
            // thumbnails alive in a scrolling track list, where the 2–5pt
            // shadow is cheap to composite directly.
            if size >= 80 {
                content
                    .shadow(
                        color: .black.opacity(opacity),
                        radius: radius,
                        x: 0,
                        y: yOffset
                    )
                    .drawingGroup()
            } else {
                content
                    .shadow(
                        color: .black.opacity(opacity),
                        radius: radius,
                        x: 0,
                        y: yOffset
                    )
            }
        } else {
            content
        }
    }
}

extension View {
    /// Apply after the artwork's `.clipShape` so the shadow matches the
    /// current corner-rounding setting automatically.
    func artworkShadow(size: CGFloat, enabled: Bool = true) -> some View {
        modifier(ArtworkShadow(size: size, enabled: enabled))
    }
}
