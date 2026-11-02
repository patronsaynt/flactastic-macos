import SwiftUI

/// Library-derived audio-fidelity panel (formerly "Studio Quality Index").
/// Compact on Home: the score, how the library splits across the quality
/// tiers, and its formats at a glance. Details opens the full spec sheet
/// (format, bit-depth and sample-rate breakdowns) in place. Recomputes from
/// `library.tracks` on every change, so each breakdown only ever shows values
/// present in the current library. Colored from the Home banner palette when
/// there is one; otherwise series are told apart by gray shade.
struct FidelidexView: View {
    @Environment(LibraryStore.self) private var library
    var palette: HomePalette? = nil

    @State private var showsDetails = false

    private var fidelity: LibraryFidelity { LibraryFidelity(tracks: library.tracks) }

    var body: some View {
        let f = fidelity
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: "Fidelidex", subtitle: "Audio fidelity across your library") {
                if !f.isEmpty {
                    Button(showsDetails ? "Hide details" : "Details") {
                        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)) { showsDetails.toggle() }
                    }
                    .buttonStyle(QuietTextButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if f.isEmpty {
                    Text("No audio files in your library yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    HStack(alignment: .center, spacing: 32) {
                        compactScore(f).frame(width: 220, alignment: .leading)
                        compactBreakdown(f)
                    }
                    if showsDetails {
                        HStack(alignment: .top, spacing: 40) {
                            VStack(alignment: .leading, spacing: 28) {
                                formatBlock(f)
                                bitDepthBlock(f)
                            }
                            sampleRateBlock(f)
                        }
                        .padding(.top, 22)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
                        .padding(.top, 22)
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
        }
    }

    private func compactScore(_ f: LibraryFidelity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(f.score)")
                    .font(.system(size: 64, weight: .heavy))
                    .tracking(-2.5)
                    .monospacedDigit()
                    .foregroundStyle(palette?.accent ?? Theme.textPrimary)
                Text("/ 100")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("Fidelity score across \(f.totalFiles.formatted()) files")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// The quality tiers as one bar in their own colours, then the formats,
    /// deepest bit depth and highest rates as chips.
    private func compactBreakdown(_ f: LibraryFidelity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedBar(segments: f.tiers.map { ($0.fraction, $0.quality.color) })
                .frame(height: 12)
            HStack(spacing: 18) {
                ForEach(f.tiers, id: \.quality) { tier in
                    (Text(percent(tier.fraction)).foregroundColor(tier.quality.color).fontWeight(.bold) + Text(" \(tier.quality.label)"))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(f.formats.prefix(3)) { chip($0.name, percent($0.fraction)) }
                if let deepest = f.depths.first, deepest.bits > 16 {
                    chip("\(deepest.bits)-bit", percent(deepest.fraction))
                }
                let hiRate = f.rates.filter { $0.rate > 48000 }
                if !hiRate.isEmpty {
                    chip("Above 48 kHz", percent(Double(hiRate.map(\.count).reduce(0, +)) / Double(max(f.totalFiles, 1))))
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ name: String, _ value: String) -> some View {
        (Text(name) + Text(" ") + Text(value).foregroundColor(Theme.textPrimary).fontWeight(.bold))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
    }

    // MARK: - File format

    private func formatBlock(_ f: LibraryFidelity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            blockTitle("File Format")
            SegmentedBar(segments: f.formats.enumerated().map { idx, slice in
                (slice.fraction, shade(idx))
            })
            .frame(height: 14)
            FlowLayout(spacing: 22, lineSpacing: 8) {
                ForEach(Array(f.formats.enumerated()), id: \.element.id) { idx, slice in
                    legendItem(slice.name, percent(slice.fraction), shade(idx))
                }
            }
        }
    }

    // MARK: - Bit depth

    private func bitDepthBlock(_ f: LibraryFidelity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            blockTitle("Bit Depth")
            if f.depths.isEmpty {
                Text("No bit-depth metadata")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                SegmentedBar(segments: f.depths.enumerated().map { idx, depth in
                    (depth.fraction, shade(idx))
                })
                .frame(height: 14)
                FlowLayout(spacing: 22, lineSpacing: 8) {
                    ForEach(Array(f.depths.enumerated()), id: \.element.id) { idx, depth in
                        legendItem(depthLabel(depth.bits), percent(depth.fraction), shade(idx))
                    }
                }
            }
        }
    }

    /// "24-bit · Hi-Res", "16-bit · CD", or just "8-bit" below CD depth.
    private func depthLabel(_ bits: Int) -> String {
        switch bits {
        case let b where b > 16: return "\(bits)-bit · Hi-Res"
        case 16:                 return "16-bit · CD"
        default:                 return "\(bits)-bit"
        }
    }

    // MARK: - Sample rates

    private func sampleRateBlock(_ f: LibraryFidelity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            blockTitle("Sample Rates")
                .padding(.bottom, 8)
            ForEach(f.rates) { rate in
                HStack(spacing: 14) {
                    Text(rate.label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 84, alignment: .leading)
                    Text(rate.tier)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 100, alignment: .leading)
                    ProgressBar(fraction: rate.fraction, tint: palette?.accent ?? Theme.textPrimary.opacity(0.7))
                    Text(rate.count.formatted())
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.surface).frame(height: 1)
                }
            }
        }
    }

    // MARK: - Building blocks

    private func blockTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }

    private func legendItem(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Series color for a breakdown, most common first: the banner palette
    /// when there is one, otherwise a gray ladder.
    private func shade(_ idx: Int) -> Color {
        let steps = [0.85, 0.55, 0.38, 0.26, 0.18, 0.12]
        let i = idx.clamped(to: 0..<steps.count)
        if let palette { return palette.series(steps.count)[i] }
        return Theme.textPrimary.opacity(steps[i])
    }
}

// MARK: - Segmented bar

/// A single horizontal bar split into proportional, rounded segments that fill
/// the available width exactly. Fractions are expected to sum to ~1.
private struct SegmentedBar: View {
    let segments: [(fraction: Double, color: Color)]

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let gaps = CGFloat(max(segments.count - 1, 0)) * spacing
            let available = max(0, geo.size.width - gaps)
            HStack(spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(seg.color)
                        .frame(width: available * CGFloat(min(max(seg.fraction, 0), 1)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared progress bar

struct ProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.divider)
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
