import SwiftUI

/// A black vinyl record: fine grooves, a fixed light sheen, and the album
/// cover as its center label. Turns at 33⅓ rpm while its album plays.
struct VinylRecord: View {
    let artwork: Data?
    let albumID: String
    let diameter: CGFloat
    let isSpinning: Bool
    /// `false` when the caller draws the record's shadow itself (the album
    /// shelf uses a pre-rendered one, so a moving record isn't re-blurred).
    var castsShadow = true

    /// One revolution at 33⅓ rpm.
    private static let revolution: TimeInterval = 1.8

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: !isSpinning)) { context in
                let angle = isSpinning
                    ? context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.revolution) / Self.revolution * 360
                    : 0
                disc.rotationEffect(.degrees(angle))
            }
            // The sheen stays put while the disc turns under it.
            Circle()
                .fill(AngularGradient(
                    colors: [
                        .clear, .white.opacity(0.13), .clear, .clear,
                        .white.opacity(0.09), .clear, .clear,
                    ],
                    center: .center,
                    angle: .degrees(-35)
                ))
            // Plain blending rather than `.screen`: over a near-black disc
            // the two look the same, and this needs no offscreen pass.
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(castsShadow ? 0.45 : 0), radius: castsShadow ? 14 : 0, y: castsShadow ? 6 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(Color(white: 0.055))
            // Grooves: thin rings across the playing surface.
            ForEach(0..<9, id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(ring.isMultiple(of: 3) ? 0.07 : 0.035), lineWidth: 0.75)
                    .padding(diameter * (0.03 + Double(ring) * 0.033))
            }
            ArtworkView(data: artwork, size: (diameter * 0.36).rounded(), id: "album:\(albumID)", showsShadow: false)
                .clipShape(Circle())
            // Spindle hole.
            Circle()
                .fill(Color(white: 0.03))
                .frame(width: max(4, diameter * 0.028), height: max(4, diameter * 0.028))
        }
    }
}
