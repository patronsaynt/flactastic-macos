import SwiftUI

/// Record: the track on the left, and a big record cut off by the window's
/// right edge, its label the album cover, turning at 33⅓ while music plays.
struct RecordVisualizerView: View {
    @Environment(PlayerState.self) private var player
    @Environment(\.topBarInset) private var topBarInset

    @State private var arrived = false

    var body: some View {
        GeometryReader { geo in
            let room = geo.size.height - topBarInset
            let diameter = min(1000, max(560, room * 1.3))
            let track = player.currentTrack

            ZStack(alignment: .topLeading) {
                SpinningRecord(
                    artwork: track?.artwork,
                    artworkID: track.map { "track:\($0.id)" } ?? "none",
                    diameter: diameter,
                    isPlaying: player.isAdvancing
                )
                // Most of the record sits past the right edge.
                .position(x: geo.size.width - diameter * 0.02, y: topBarInset + room / 2)
                .offset(x: arrived ? 0 : diameter * 0.42)
                .rotationEffect(.degrees(arrived ? 0 : 50))

                details(track: track, width: min(520, geo.size.width - diameter * 0.52 - 140))
                    .padding(.leading, 96)
                    .frame(height: room)
                    .offset(y: topBarInset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.2)) { arrived = true }
        }
    }

    private func details(track: Track?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(data: track?.artwork, size: 260, id: track.map { "track:\($0.id)" })
            VisualizerTrackDetails(track: track, titleSize: 60, artistSize: 20, albumSize: 15)
                .padding(.top, 34)
            VisualizerSpecChip(track: track)
                .padding(.top, 18)
            PlaybackProgressBar()
                .frame(width: min(420, width))
                .padding(.top, 26)
        }
        .frame(width: max(260, width), alignment: .leading)
    }
}

/// The record itself. The disc is flattened to one layer and only rotated,
/// so turning it costs a transform per frame; the light on it stays put.
private struct SpinningRecord: View {
    let artwork: Data?
    let artworkID: String
    let diameter: CGFloat
    let isPlaying: Bool

    /// One revolution at 33⅓ rpm.
    private static let revolution: TimeInterval = 1.8

    /// Angle reached before the last pause, and when playing last resumed,
    /// so pausing stops the record where it is rather than snapping it back.
    @State private var restingAngle: Double = 0
    @State private var resumedAt: Date = .now

    var body: some View {
        ZStack {
            // The shadow comes from a still circle behind the disc, so it's
            // drawn once instead of being re-derived from the turning disc
            // every frame.
            Circle()
                .fill(Color(white: 0.05))
                .shadow(color: .black.opacity(0.75), radius: 45, x: -30, y: 24)
            TimelineView(.animation(paused: !isPlaying)) { context in
                // Equatable, so each frame only re-applies the rotation; the
                // grooves and label are drawn once.
                RecordDisc(artwork: artwork, artworkID: artworkID, diameter: diameter)
                    .equatable()
                    .rotationEffect(.degrees(angle(at: context.date)))
            }
            sheen
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: isPlaying) { _, playing in
            if playing {
                resumedAt = .now
            } else {
                restingAngle = angle(at: .now)
            }
        }
        .onAppear { resumedAt = .now }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func angle(at date: Date) -> Double {
        guard isPlaying else { return restingAngle }
        let turned = date.timeIntervalSince(resumedAt) / Self.revolution * 360
        return (restingAngle + turned).truncatingRemainder(dividingBy: 360)
    }

    /// Two soft bands of reflected light that don't turn with the disc.
    private var sheen: some View {
        Circle()
            .fill(AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.09), location: 0.05),
                    .init(color: .clear, location: 0.12),
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.07), location: 0.56),
                    .init(color: .clear, location: 0.63),
                    .init(color: .clear, location: 1),
                ],
                center: .center,
                angle: .degrees(20)
            ))
            .mask(
                Circle().fill(RadialGradient(
                    stops: [.init(color: .clear, location: 0.35), .init(color: .black, location: 0.37)],
                    center: .center, startRadius: 0, endRadius: diameter / 2
                ))
            )
            .allowsHitTesting(false)
    }
}

/// The record's surface: grooves, the cover as its label, the spindle hole.
private struct RecordDisc: View, Equatable {
    let artwork: Data?
    let artworkID: String
    let diameter: CGFloat

    nonisolated static func == (a: RecordDisc, b: RecordDisc) -> Bool {
        a.artworkID == b.artworkID && a.diameter == b.diameter
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = size.width / 2
                ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.05)))
                // Grooves, with a darker gap between each band of the album.
                var radius = r * 0.19
                var ring = 0
                while radius < r * 0.985 {
                    let bandGap = [0.30, 0.42, 0.54, 0.66, 0.78].contains { abs(radius / r - $0) < 0.004 }
                    let color: Color = bandGap ? .black.opacity(0.7) : .white.opacity(ring.isMultiple(of: 2) ? 0.045 : 0.025)
                    ctx.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(color), lineWidth: bandGap ? 2.5 : 0.8)
                    radius += 2.6
                    ring += 1
                }
            }
            ArtworkView(data: artwork, size: (diameter * 0.34).rounded(), id: artworkID, showsShadow: false)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 2))
            Circle()
                .fill(Theme.background)
                .frame(width: 18, height: 18)
        }
        .frame(width: diameter, height: diameter)
        .drawingGroup()
    }
}
