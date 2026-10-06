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
