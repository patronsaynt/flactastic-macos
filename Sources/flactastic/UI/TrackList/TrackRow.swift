import SwiftUI

struct TrackRow: View {
    /// Shared with `FLTrackListHeader` so the FORMAT / QUALITY / LENGTH column
    /// headers stay aligned with these badges regardless of content length.
    /// Fixed, not minimum, widths: sized for the longest values ("Hi-Res ·
    /// 24/192", "Mid · 44.1 kHz", "1:00:03") so a long badge or an hour-long
    /// track can't push its neighbours out of line.
    static let formatColumnWidth: CGFloat = 56
    static let qualityColumnWidth: CGFloat = 124
    static let lengthColumnWidth: CGFloat = 60

    let track: Track
    let isPlaying: Bool
    var displayNumber: Int? = nil
    /// When `true`, a subtle drag-handle icon is shown at the trailing edge
    /// to signal that the row can be reordered by dragging.
    var showDragHandle: Bool = false
    var showAlbumArt: Bool = false
    /// When `true`, the secondary line reads "artist — album" instead of just
    /// the artist. Used by the flat All Tracks list, where the album isn't
    /// implied by context.
    var showAlbumInSubtitle: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            if showAlbumArt && displayNumber != nil {
                numberWithAlbumArt
            } else if showAlbumArt {
                albumArtOrIndicator
            } else {
                trackNumberOrIndicator
                    .frame(width: 26, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(isPlaying ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            // File format badge
            Text(track.fileFormat.displayName)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: Self.formatColumnWidth - 14, alignment: .center)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.surfaceElevated)
                )

            // Quality badge
            qualityBadge

            Text(FormatUtils.formatDuration(track.duration))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: Self.lengthColumnWidth, alignment: .trailing)

            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
                    .frame(width: 18)
            }
        }
    }

    private var subtitle: String? {
        let artist = ArtistResolver.displayString(track.artist)
        guard showAlbumInSubtitle, let album = track.album, !album.isEmpty else { return artist }
        guard let artist else { return album }
        return "\(artist) — \(album)"
    }

    @ViewBuilder
    private var albumArtOrIndicator: some View {
        if isPlaying {
            ArtworkView(data: track.artwork, size: 34)
                .overlay(alignment: .center) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
        } else {
            ArtworkView(data: track.artwork, size: 34)
        }
    }

    @ViewBuilder
    private var numberWithAlbumArt: some View {
        HStack(spacing: 14) {
            trackNumberOrIndicator
                .frame(width: 26, alignment: .center)

            ArtworkView(data: track.artwork, size: 34)
        }
    }

    @ViewBuilder
    private var trackNumberOrIndicator: some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
        } else if let num = displayNumber ?? track.trackNumber {
            Text(String(format: "%02d", num))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        } else {
            Text("")
        }
    }

    private var qualityBadge: some View {
        TrackQualityBadge(track: track)
    }
}
