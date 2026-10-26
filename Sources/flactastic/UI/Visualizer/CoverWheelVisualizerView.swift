import SwiftUI

/// Cover Wheel: the playing cover forward with two from the queue either
/// side, falling away into the distance; the track's details below.
struct CoverWheelVisualizerView: View {
    @Environment(PlayerState.self) private var player
    @Environment(\.topBarInset) private var topBarInset

    /// Two covers either side of the current one.
    private let halfWindow: Int = 2

    var body: some View {
        GeometryReader { geo in
            let room = geo.size.height - topBarInset
            let centerSize = min(300, min(geo.size.width, room) * 0.42)
            // A 186pt step against a 300pt cover; scaled so the overlap reads
            // the same at any cover size.
            let spacing = centerSize * (186.0 / 300.0)

            VStack(spacing: 44) {
                ZStack {
                    ForEach(visibleEntries(), id: \.id) { entry in
                        cover(entry, size: centerSize, spacing: spacing)
                    }
                }
                .frame(height: centerSize)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.75),
                           value: player.currentIndex)

                VStack(spacing: 0) {
                    VisualizerTrackDetails(
                        track: player.currentTrack,
                        titleSize: 40, artistSize: 18, albumSize: 14,
                        alignment: .center
                    )
                    queueDots
                        .padding(.top, 22)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, Theme.Spacing.xxl)
            }
            .frame(width: geo.size.width, height: room)
            .offset(y: topBarInset)
        }
    }

    /// One cover in the wheel. Outer covers shrink, fade, desaturate and blur
    /// with distance from the current track.
    private func cover(_ entry: Entry, size: CGFloat, spacing: CGFloat) -> some View {
        let offset = CGFloat(entry.relativeIndex)
        let distance = abs(offset)
        let scale: CGFloat = max(0.55, 1.0 - distance * 0.18)
        let opacity: Double = max(0.18, 1.0 - Double(distance) * 0.3)
        let grayscale: Double = entry.relativeIndex == 0 ? 0 : 0.45
        return ArtworkView(data: entry.track.artwork, size: size, id: "track:\(entry.track.id)")
            .grayscale(grayscale)
            .blur(radius: distance * 1.6)
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: offset * spacing)
            .zIndex(-Double(distance))
    }

    /// One dot per cover in the visible window, the current track's filled and
    /// enlarged. Gives the wheel a sense of position within the queue.
    private var queueDots: some View {
        HStack(spacing: 7) {
            ForEach(visibleEntries(), id: \.id) { entry in
                let isCurrent = entry.relativeIndex == 0
                Circle()
                    .fill(isCurrent ? Theme.accent : Theme.accent.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isCurrent ? 1.4 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: player.currentIndex)
    }

    private struct Entry: Identifiable {
        let id: UUID
        let track: Track
        let relativeIndex: Int
    }

    private func visibleEntries() -> [Entry] {
        let q = player.queue
        guard !q.isEmpty else { return [] }
        let cur = player.currentIndex
        var out: [Entry] = []
        for delta in -halfWindow...halfWindow {
            let idx = cur + delta
            guard idx >= 0, idx < q.count else { continue }
            out.append(Entry(id: q[idx].id, track: q[idx], relativeIndex: delta))
        }
        return out
    }
}
