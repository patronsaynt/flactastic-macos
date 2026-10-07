import SwiftUI

// Fidelity labels read from the files themselves: the per-track badge and
// the album-level summary used on the shelf, the album page and the artist
// spotlight.

extension AudioQuality {
    /// Low to Hi-Res, for sorting and for finding an album's range.
    var rank: Int {
        switch self {
        case .low: return 0
        case .mid: return 1
        case .cd: return 2
        case .hiRes: return 3
        }
    }

    static func of(_ track: Track) -> AudioQuality {
        classify(sampleRate: track.sampleRate, bitDepth: track.bitDepth, format: track.fileFormat)
    }
}

/// The tier-colored badge on track rows: "Hi-Res · 24/96".
struct TrackQualityBadge: View {
    let track: Track

    var body: some View {
        let quality = AudioQuality.of(track)
        let detail = FormatUtils.formatSampleRate(track.sampleRate, bitDepth: track.bitDepth)
        let label = detail.map { "\(quality.label) · \($0)" } ?? quality.label

        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(quality.color)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: TrackRow.qualityColumnWidth - 14, alignment: .center)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(quality.color.opacity(0.12))
            )
    }
}

extension Album {
    /// The album's fidelity: the exact spec when every track shares it,
    /// otherwise the range of tiers it spans, colored by the lowest so it
    /// never overstates the album.
    @MainActor var qualitySummary: (text: String, color: Color)? {
        guard !tracks.isEmpty else { return nil }
        let tiers = tracks.map(AudioQuality.of)
        let lowest = tiers.min { $0.rank < $1.rank } ?? tiers[0]
        let highest = tiers.max { $0.rank < $1.rank } ?? tiers[0]
        let specs = Set(tracks.map { FormatUtils.techSpec(for: $0) ?? "" })
        if specs.count == 1, let spec = specs.first, !spec.isEmpty {
            return ("\(lowest.label) · \(spec)", lowest.color)
        }
        if lowest.rank == highest.rank {
            return (lowest.label, lowest.color)
        }
        return ("\(lowest.label) to \(highest.label)", lowest.color)
    }
}

/// A playlist's spread of quality tiers: a thin bar split by tier, Hi-Res
/// first, with the leading shares spelled out beside it.
struct QualityMixBar: View {
    let tracks: [Track]
    var width: CGFloat = 200
    /// Colour for the share text; the tier names keep their own colours.
    var ink: Color = Theme.textSecondary

    private struct Share: Identifiable {
        let quality: AudioQuality
        let count: Int
        var id: Int { quality.rank }
    }

    private var shares: [Share] {
        var counts: [Int: Int] = [:]
        for track in tracks { counts[AudioQuality.of(track).rank, default: 0] += 1 }
        return [AudioQuality.hiRes, .cd, .mid, .low].compactMap { quality in
            counts[quality.rank].map { Share(quality: quality, count: $0) }
        }
    }

    var body: some View {
        let shares = shares
        let total = max(1, shares.reduce(0) { $0 + $1.count })
        let gaps = CGFloat(max(0, shares.count - 1)) * 2
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(shares) { share in
                    Capsule()
                        .fill(share.quality.color)
                        .frame(width: max(3, (width - gaps) * CGFloat(share.count) / CGFloat(total)))
                }
            }
            .frame(width: width, height: 6, alignment: .leading)
            .clipShape(Capsule())

            HStack(spacing: 0) {
                ForEach(Array(shares.prefix(3).enumerated()), id: \.element.id) { index, share in
                    if index > 0 { Text(" · ").foregroundStyle(ink) }
                    Text("\(Int((Double(share.count) / Double(total) * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundStyle(share.quality.color)
                    Text(" \(share.quality.label)").foregroundStyle(ink)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shares.map { "\($0.count) \($0.quality.label)" }.joined(separator: ", "))
    }
}
