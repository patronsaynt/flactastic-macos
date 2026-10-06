import SwiftUI

// Controls that sit on top of full-bleed artwork heroes (the artist banner
// and the album page backdrop).

/// Pill buttons that sit on the banner: ink-filled primary, translucent
/// secondary. Ink is white over the dark hero and near-black over the light
/// tint.
struct HeroPillStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    let kind: Kind
    let ink: Color
    let isLight: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let isPrimary = kind == .primary
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: isPrimary && !compact ? 14 : 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isPrimary ? (isLight ? Color.white : Color.black) : ink)
            .padding(.horizontal, isPrimary && !compact ? 24 : 18)
            .frame(height: compact ? 32 : (isPrimary ? 44 : 36))
            .background {
                if isPrimary {
                    Capsule().fill(ink)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(ink.opacity(isLight ? 0.05 : 0.1)))
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Back control that reads over imagery: a frosted dark circle.
struct HeroBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.38)))
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}
