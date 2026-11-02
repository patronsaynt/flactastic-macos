import Foundation

/// A library-derived audio-fidelity summary powering the Fidelidex panel.
/// Every breakdown lists only the values actually present in the supplied
/// tracks, so the panel fluctuates automatically as files are added or removed.
struct LibraryFidelity {
    struct FormatSlice: Identifiable {
        var id: String { name }
        let name: String          // e.g. "FLAC"
        let count: Int
        let fraction: Double      // 0…1 of total files
        let isLossless: Bool
    }

    struct DepthSlice: Identifiable {
        var id: Int { bits }
        let bits: Int             // e.g. 24
        let count: Int
        let fraction: Double
    }

    struct RateSlice: Identifiable {
        var id: Double { rate }
        let rate: Double          // Hz, e.g. 192000
        let count: Int
        let fraction: Double      // relative to the most common rate (for bar width)
        let label: String         // "192 kHz"
        let tier: String          // "Ultra Hi-Res"
    }

    let totalFiles: Int
    let formats: [FormatSlice]
    let depths: [DepthSlice]
    let rates: [RateSlice]
    let losslessFraction: Double
    let hiResCount: Int
    /// Share of files in each quality tier, best first; empty tiers left out.
    let tiers: [(quality: AudioQuality, fraction: Double)]
    /// 0…100 weighted fidelity index across the whole library.
    let score: Int

    var isEmpty: Bool { totalFiles == 0 }

    init(tracks: [Track]) {
        totalFiles = tracks.count
        guard !tracks.isEmpty else {
            formats = []; depths = []; rates = []; tiers = []
            losslessFraction = 0; hiResCount = 0; score = 0
            return
        }

        let total = Double(tracks.count)

        // ── Formats ──
        let losslessFormats: Set<AudioFileFormat> = [.flac, .wav, .aiff, .alac]
        var formatCounts: [AudioFileFormat: Int] = [:]
        for t in tracks { formatCounts[t.fileFormat, default: 0] += 1 }
        formats = formatCounts
            .map { fmt, count in
                FormatSlice(
                    name: fmt.displayName,
                    count: count,
                    fraction: Double(count) / total,
                    isLossless: losslessFormats.contains(fmt)
                )
            }
            .sorted { $0.count > $1.count }

        // ── Bit depths (only present values) ──
        var depthCounts: [Int: Int] = [:]
        for t in tracks { if let d = t.bitDepth { depthCounts[d, default: 0] += 1 } }
        let depthTotal = Double(depthCounts.values.reduce(0, +))
        depths = depthCounts
            .map { bits, count in
                DepthSlice(
                    bits: bits,
                    count: count,
                    fraction: depthTotal > 0 ? Double(count) / depthTotal : 0
                )
            }
            .sorted { $0.bits > $1.bits }

        // ── Sample rates (only present values) ──
        var rateCounts: [Double: Int] = [:]
        for t in tracks { if let r = t.sampleRate, r > 0 { rateCounts[r, default: 0] += 1 } }
        let maxRateCount = Double(rateCounts.values.max() ?? 1)
        rates = rateCounts
            .map { rate, count in
                RateSlice(
                    rate: rate,
                    count: count,
                    fraction: maxRateCount > 0 ? Double(count) / maxRateCount : 0,
                    label: Self.rateLabel(rate),
                    tier: Self.rateTier(rate)
                )
            }
            .sorted { $0.rate > $1.rate }

        // ── Aggregate quality metrics ──
        let losslessCount = tracks.filter { losslessFormats.contains($0.fileFormat) }.count
        losslessFraction = Double(losslessCount) / total
        hiResCount = tracks.filter { ($0.bitDepth ?? 0) > 16 || ($0.sampleRate ?? 0) > 48000 }.count

        // Score: each file scored by quality tier, averaged to 0…100.
        let tierScore: (Track) -> Double = { t in
            switch AudioQuality.classify(sampleRate: t.sampleRate, bitDepth: t.bitDepth, format: t.fileFormat) {
            case .hiRes: return 100
            case .cd:    return 80
            case .mid:   return 55
            case .low:   return 30
            }
        }
        let avg = tracks.map(tierScore).reduce(0, +) / total
        score = Int(avg.rounded())

        var tierCounts: [AudioQuality: Int] = [:]
        for t in tracks {
            tierCounts[AudioQuality.classify(sampleRate: t.sampleRate, bitDepth: t.bitDepth, format: t.fileFormat), default: 0] += 1
        }
        tiers = [AudioQuality.hiRes, .cd, .mid, .low].compactMap { q in
            tierCounts[q].map { (q, Double($0) / total) }
        }
    }

    private static func rateLabel(_ rate: Double) -> String {
        let khz = rate / 1000.0
        if khz == khz.rounded() {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }

    private static func rateTier(_ rate: Double) -> String {
        switch rate {
        case let r where r >= 176400: return "Ultra Hi-Res"
        case let r where r > 48000:   return "Hi-Res"
        case let r where r > 44100:   return "Studio"
        case 44100:                   return "CD Quality"
        default:                      return "Standard"
        }
    }
}
