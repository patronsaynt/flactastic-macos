import SwiftUI

/// Karaoke-style lyrics scroller. The active line is rendered large and sharp;
/// surrounding lines shrink, fade and blur away with distance, and the whole
/// stack slides as `currentTime` advances.
///
/// Lines are positioned absolutely around a centre anchor rather than stacked
/// in a `VStack` — per-line blur and scale need each row to keep its own
/// geometry, and a flow layout would reshuffle the whole column every time a
/// line's scale changed. Each line's offset is computed from the measured
/// (wrapped) heights of the lines between it and the active one, so a lyric
/// that wraps onto two lines pushes its neighbours away instead of
/// overlapping them.
struct LyricsScrollerView: View {
    let lyrics: Lyrics
    let currentTime: TimeInterval
    /// Overrides the time-derived active line. Used for unsynced lyrics,
    /// where the listener steps through lines by hand.
    var activeIndex: Int? = nil
    var alignment: HorizontalAlignment = .center
    /// Size of the active line. Surrounding lines use the same face, scaled
    /// down by their distance.
    var fontSize: CGFloat = 44
    var activeStyle: AnyShapeStyle = AnyShapeStyle(Theme.textPrimary)
    /// Fraction of the container the text may occupy before wrapping.
    var maxWidthFraction: CGFloat = 0.72

    /// Lines rendered either side of the active one. Beyond ±4 the design's
    /// opacity curve has already reached zero.
    private let window: Int = 4

    /// Scale applied to every non-active line.
    private static let neighborScale: CGFloat = 0.72

    /// Unscaled layout height of each rendered line, keyed by line index.
    /// Re-measured whenever wrapping changes (container width, font size).
    @State private var lineHeights: [Int: CGFloat] = [:]

    /// Visual gap between consecutive lines, after scaling.
    private var lineGap: CGFloat { fontSize * 0.5 }

    var body: some View {
        let idx = activeIndex.map { min(max($0, 0), max(lyrics.lines.count - 1, 0)) }
            ?? lyrics.currentLineIndex(at: currentTime) ?? 0
        GeometryReader { geo in
            ZStack(alignment: .init(horizontal: alignment, vertical: .center)) {
                // Identity is the absolute line index, NOT the relative offset.
                // Keying on the offset would make each slot a stable view whose
                // *text* changes on every advance, so SwiftUI would cross-fade
                // the words in place instead of sliding the lines upward.
                let offsets = yOffsets(around: idx)
                ForEach(visibleIndices(around: idx), id: \.self) { i in
                    line(lyrics.lines[i].text, index: i, distance: i - idx,
                         y: offsets[i] ?? 0, width: geo.size.width)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.85), value: idx)
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    /// The lines to render, clamped to the lyric's own bounds.
    private func visibleIndices(around idx: Int) -> [Int] {
        let lower = max(0, idx - window)
        let upper = min(lyrics.lines.count - 1, idx + window)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    /// Scaled height of line `i` as it will appear on screen at `distance`.
    private func visualHeight(of i: Int, distance d: Int) -> CGFloat {
        // Before the first measurement, assume a single line of text.
        let h = lineHeights[i] ?? fontSize * 1.2
        return d == 0 ? h : h * Self.neighborScale
    }

    /// Vertical centre of every visible line relative to the active line's
    /// centre, stacking outward with `lineGap` between visual edges.
    private func yOffsets(around idx: Int) -> [Int: CGFloat] {
        var offsets: [Int: CGFloat] = [idx: 0]
        for direction in [1, -1] {
            var edge = visualHeight(of: idx, distance: 0) / 2
            var i = idx + direction
            while abs(i - idx) <= window, lyrics.lines.indices.contains(i) {
                let h = visualHeight(of: i, distance: i - idx)
                offsets[i] = CGFloat(direction) * (edge + lineGap + h / 2)
                edge += lineGap + h
                i += direction
            }
        }
        return offsets
    }

    private func line(_ text: String, index i: Int, distance d: Int, y: CGFloat, width: CGFloat) -> some View {
        let metrics = Self.metrics(distance: d)
        return Text(text.isEmpty ? " " : text)
            .font(.system(size: fontSize, weight: .heavy))
            .tracking(-fontSize * 0.03)
            .foregroundStyle(activeStyle)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .frame(maxWidth: width * maxWidthFraction,
                   alignment: .init(horizontal: alignment, vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeights[i] = $0 }
            .scaleEffect(metrics.scale, anchor: alignment == .leading ? .leading : .center)
            .opacity(metrics.opacity)
            .blur(radius: metrics.blur)
            .offset(y: y)
    }

    /// Per-line falloff: the sung line full size; neighbors at 72%, fading
    /// and softening with distance.
    private static func metrics(distance d: Int) -> (scale: CGFloat, opacity: Double, blur: CGFloat) {
        let ad = abs(d)
        if ad == 0 {
            return (scale: 1, opacity: 1, blur: 0)
        }
        let opacity: Double = [0.5, 0.28, 0.14, 0.06][min(ad, 4) - 1]
        return (
            scale: neighborScale,
            opacity: opacity,
            blur: ad <= 1 ? 0 : CGFloat(ad - 1) * 1.6
        )
    }
}
