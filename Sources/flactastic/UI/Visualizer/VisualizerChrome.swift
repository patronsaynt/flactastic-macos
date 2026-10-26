import SwiftUI
import AppKit

/// Shared chrome for the visualizer modes: the mark color, the track details
/// block, the quality chip, the progress bar and the cover's palette.
enum VisualizerPalette {
    /// The color every generated mark is drawn in — spectrum bars and rings.
    /// White on dark, black on light.
    static let mark = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    })

    /// Faint guide geometry (the radial spectrum's two rings).
    static var guideRing: Color { mark.opacity(0.12) }
}

// MARK: - Track details

/// Title, artist and album, sized per mode. Long titles scroll rather than
/// wrap or truncate.
struct VisualizerTrackDetails: View {
    let track: Track?
    var titleSize: CGFloat
    var artistSize: CGFloat
    var albumSize: CGFloat
    var alignment: HorizontalAlignment = .leading
    /// Lyrics sets its chrome in white over its own dark field.
    var onDark = false

    var body: some View {
        let artist = ArtistResolver.displayString(track?.artist ?? track?.albumArtist) ?? "Unknown Artist"
        VStack(alignment: alignment, spacing: 0) {
            MarqueeText(
                text: track?.title ?? "—",
                font: .system(size: titleSize),
                weight: .heavy,
                foregroundStyle: AnyShapeStyle(onDark ? Color.white : Theme.textPrimary),
                alignment: alignment
            )
            MarqueeText(
                text: artist,
                font: .system(size: artistSize, weight: .semibold),
                foregroundStyle: AnyShapeStyle(onDark ? Color.white.opacity(0.85) : Theme.textSecondary),
                alignment: alignment
            )
            .padding(.top, titleSize * 0.2)
            if let line = albumLine {
                MarqueeText(
                    text: line,
                    font: .system(size: albumSize),
                    foregroundStyle: AnyShapeStyle(onDark ? Color.white.opacity(0.6) : Theme.textTertiary),
                    alignment: alignment
                )
                .padding(.top, 4)
            }
        }
    }

    private var albumLine: String? {
        let album = track?.album?.trimmingCharacters(in: .whitespaces)
        let parts = [album.flatMap { $0.isEmpty ? nil : $0 }, track?.year.map(String.init)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Quality chip

/// `FLAC · 24-BIT / 96 kHz` in the track's quality-tier color. Renders
/// nothing when the track carries no format or rate metadata at all.
struct VisualizerSpecChip: View {
    let track: Track?
    /// The short `24/96` form, for the spectrogram's corner.
    var compact = false

    var body: some View {
        if let track, let text = compact
            ? FormatUtils.formatSampleRate(track.sampleRate, bitDepth: track.bitDepth)
            : FormatUtils.techSpec(for: track) {
            let color = AudioQuality.of(track).color
            Text(text)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Cover palette

/// Up to three colors from the playing cover, for the modes that take their
/// color from the music (Lyrics' field, the spectrogram, the radial glow).
/// Sampled off the main thread and kept for the session.
@MainActor
enum CoverPalette {
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let palette: HomePalette?; init(_ p: HomePalette?) { palette = p } }

    static func cached(for data: Data?) -> HomePalette?? {
        guard let data, !data.isEmpty else { return .some(nil) }
        return cache.object(forKey: ArtworkImageCache.contentID(for: data) as NSString).map { $0.palette }
    }

    static func load(for data: Data?) async -> HomePalette? {
        if let hit = cached(for: data) { return hit }
        guard let data else { return nil }
        let key = ArtworkImageCache.contentID(for: data) as NSString
        let palette = await Task.detached(priority: .utility) { HomePalette.extract(from: data) }.value
        cache.setObject(Box(palette), forKey: key)
        return palette
    }
}

// MARK: - Playback-driven chrome

/// `PlayerState.currentTime` is republished 20×/s for the whole of playback,
/// and `@Observable` invalidates every view that *reads* it. When a mode's
/// body reads it directly — even just to size a progress bar — the entire mode
/// re-evaluates and AppKit re-lays-out the hosting view 20 times a second,
/// artwork, marquees and all.
///
/// These two views exist to own that dependency. They read the clock
/// themselves, so the surrounding mode body never touches `currentTime` and
/// only this small subtree is invalidated per tick.

/// A 4pt progress bar between elapsed and remaining time.
struct PlaybackProgressBar: View {
    @Environment(PlayerState.self) private var player

    var track: Color = Theme.textPrimary.opacity(0.16)
    var fill: Color = Theme.textPrimary
    var labelStyle: AnyShapeStyle = AnyShapeStyle(Theme.textTertiary)

    var body: some View {
        let total = player.duration ?? 0
        let elapsed = min(player.currentTime, total > 0 ? total : player.currentTime)
        let fraction = total > 0 ? elapsed / total : 0
        HStack(spacing: 12) {
            label(FormatUtils.formatDuration(elapsed))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(fill).frame(width: g.size.width * CGFloat(max(0, min(1, fraction))))
                }
            }
            .frame(height: 4)
            label("-" + FormatUtils.formatDuration(max(0, total - elapsed)))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(labelStyle)
    }
}

/// A standalone `0:42 / 3:15` readout.
struct PlaybackTimeReadout: View {
    @Environment(PlayerState.self) private var player

    var showsTotal: Bool = true
    var size: CGFloat = 15

    var body: some View {
        let total = player.duration ?? 0
        HStack(spacing: 4) {
            Text(FormatUtils.formatDuration(player.currentTime))
                .foregroundStyle(Theme.textSecondary)
            if showsTotal {
                Text("/ " + FormatUtils.formatDuration(total > 0 ? total : nil))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: size))
        .monospacedDigit()
        .fixedSize()
    }
}
