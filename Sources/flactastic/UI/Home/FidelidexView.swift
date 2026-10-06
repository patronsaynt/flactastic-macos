import SwiftUI

/// Library-derived audio-fidelity panel (formerly "Studio Quality Index"),
/// laid out as a spec sheet: the score and headline counts on the left, the
/// format, bit-depth and sample-rate breakdowns on the right. Recomputes from
/// `library.tracks` on every change, so each breakdown only ever shows values
/// present in the current library. Colored from the Home banner palette when
/// there is one; otherwise series are told apart by gray shade.
struct FidelidexView: View {
    @Environment(LibraryStore.self) private var library
    var palette: HomePalette? = nil

    private var fidelity: LibraryFidelity { LibraryFidelity(tracks: library.tracks) }

    var body: some View {
        let f = fidelity
        HStack(alignment: .top, spacing: 48) {
            summary(f)
                .frame(width: 300, alignment: .leading)
            if !f.isEmpty {
                VStack(alignment: .leading, spacing: 32) {
                    formatBlock(f)
                    bitDepthBlock(f)
                    sampleRateBlock(f)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 30)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: - Summary

    private func summary(_ f: LibraryFidelity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fidelidex")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Theme.textPrimary)
            Text("Audio fidelity breakdown across your library.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            if f.isEmpty {
                Text("No audio files in your library yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(f.score)")
                        .font(.system(size: 96, weight: .bold))
                        .tracking(-3.8)
                        .monospacedDigit()
                        .foregroundStyle(palette?.accent ?? Theme.textPrimary)
                    Text("/ 100")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 8)
                Text("Fidelity score")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)

                HStack(alignment: .top, spacing: 16) {
                    summaryStat(percent(f.losslessFraction), "Lossless")
                    summaryStat(f.hiResCount.formatted(), "Hi-Res files")
                    summaryStat(f.totalFiles.formatted(), "Total files")
                }
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.surfaceElevated).frame(height: 1)
                }
                .padding(.top, 14)
            }
        }
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
