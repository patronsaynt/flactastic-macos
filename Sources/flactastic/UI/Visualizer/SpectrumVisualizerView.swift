import SwiftUI
import AppKit

/// The three spectrum modes. Only the spectrum views themselves read the
/// analyzer's 60 Hz `magnitudes`, inside their own bodies, so each frame
/// redraws the bars and nothing else: the artwork, titles and layout around
/// them are left alone.
struct SpectrumVisualizerView: View {
    @Environment(PlayerState.self) private var player
    @Environment(\.topBarInset) private var topBarInset
    let mode: VisualizerMode
    let analyzer: SpectrumAnalyzer

    /// The playing cover's colors: the radial ring's glow and the
    /// spectrogram's low-to-high gradient. nil for a gray or missing cover.
    @State private var palette: HomePalette?

    var body: some View {
        Group {
            switch mode {
            case .spectrumRadial:      radialLayout
            case .spectrumHorizontal:  horizontalLayout
            case .spectrogram:         spectrogramLayout
            default:                   EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: player.currentTrack?.id) {
            let sampled = await CoverPalette.load(for: player.currentTrack?.artwork)
            guard !Task.isCancelled else { return }
            palette = sampled
        }
    }

    // MARK: - Radial: the ring above, the track centered below it.

    /// The ring and the track below it travel as one group, centered in the
    /// space between the top bar and the progress bar along the bottom, so
    /// the composition sits in the middle of the page rather than hanging
    /// from the top bar.
    private var radialLayout: some View {
        GeometryReader { geo in
            let progressBand: CGFloat = 96
            let room = geo.size.height - topBarInset - progressBand
            let ring = min(400, room * 0.56, geo.size.width * 0.6)
            ZStack(alignment: .bottom) {
                VStack(spacing: 28) {
                    RadialSpectrum(analyzer: analyzer, glow: palette?.series(1).first)
                        .frame(width: ring, height: ring)

                    HStack(alignment: .center, spacing: 26) {
                        ArtworkView(data: player.currentTrack?.artwork, size: 112,
                                    id: player.currentTrack.map { "track:\($0.id)" })
                        VStack(alignment: .leading, spacing: 12) {
                            VisualizerTrackDetails(track: player.currentTrack,
                                                   titleSize: 36, artistSize: 17, albumSize: 14)
                            VisualizerSpecChip(track: player.currentTrack)
                        }
                        .frame(width: min(420, geo.size.width * 0.4), alignment: .leading)
                    }
                }
                .frame(width: geo.size.width, height: room)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, progressBand)

                PlaybackProgressBar()
                    .frame(width: min(520, geo.size.width * 0.6))
                    .padding(.bottom, 44)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Horizontal: spectrum above, details below.

    private var horizontalLayout: some View {
        VStack(spacing: 50) {
            HorizontalSpectrum(analyzer: analyzer)
                .frame(height: 300)

            HStack(alignment: .center, spacing: 22) {
                ArtworkView(data: player.currentTrack?.artwork, size: 108,
                            id: player.currentTrack.map { "track:\($0.id)" })
                VStack(alignment: .leading, spacing: 12) {
                    VisualizerTrackDetails(track: player.currentTrack,
                                           titleSize: 32, artistSize: 16, albumSize: 13)
                    VisualizerSpecChip(track: player.currentTrack)
                }
                Spacer(minLength: 0)
                PlaybackTimeReadout()
            }
        }
        .frame(maxWidth: 880)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, topBarInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Spectrogram: full-canvas stipple with corner chrome.

    private var spectrogramLayout: some View {
        let track = player.currentTrack
        return ZStack {
            // Runs the full height of the window, under the top bar, and
            // fades out toward the top edge.
            SpectrogramStipple(analyzer: analyzer, palette: palette)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            LinearGradient(
                colors: [Theme.background.opacity(0), Theme.background.opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 180)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            HStack(alignment: .center, spacing: 18) {
                ArtworkView(data: track?.artwork, size: 72, id: track.map { "track:\($0.id)" })
                VisualizerTrackDetails(track: track, titleSize: 26, artistSize: 15, albumSize: 12)
                    .frame(maxWidth: 520, alignment: .leading)
                Spacer(minLength: 24)
                if let palette {
                    HStack(spacing: 4) {
                        ForEach(Array(palette.series(3).enumerated()), id: \.offset) { _, color in
                            Circle().fill(color).frame(width: 10, height: 10)
                        }
                    }
                    .help("Colors from the album cover")
                }
                VisualizerSpecChip(track: track, compact: true)
                PlaybackTimeReadout(showsTotal: false)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Radial

private struct RadialSpectrum: View {
    let analyzer: SpectrumAnalyzer
    /// The cover's main color, glowing inside the ring with the bass.
    var glow: Color?

    var body: some View {
        let magnitudes = analyzer.magnitudes
        GeometryReader { geo in
            let minSide = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Keep total radius (inner + maxBar) ≤ minSide / 2 so the bars
            // never spill past the visualizer canvas at any aspect ratio.
            let inner = minSide * 0.29
            let maxBar = minSide * 0.18

            Canvas { ctx, _ in
                let count = magnitudes.count
                guard count > 0 else { return }

                if let glow {
                    let bass = Double(magnitudes.prefix(3).max() ?? 0)
                    let disk = CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)
                    ctx.fill(Path(ellipseIn: disk), with: .radialGradient(
                        Gradient(colors: [glow.opacity(0.16 + bass * 0.3), glow.opacity(0)]),
                        center: center, startRadius: 0, endRadius: inner
                    ))
                }

                for radius in [inner - 10, inner + maxBar + 14] {
                    ctx.stroke(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(VisualizerPalette.guideRing),
                        lineWidth: 1
                    )
                }

                // Mirrored spokes: the low bins run down one half of the
                // circle and back up the other, so the figure is symmetric
                // instead of seaming at 12 o'clock.
                let spokes = count * 2
                for i in 0..<spokes {
                    let mag = CGFloat(magnitudes[i < count ? i : spokes - 1 - i])
                    let angle = (Double(i) / Double(spokes)) * .pi * 2 - .pi / 2
                    let length = inner + maxBar * mag
                    let cosA = cos(angle), sinA = sin(angle)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + cosA * inner,
                                          y: center.y + sinA * inner))
                    path.addLine(to: CGPoint(x: center.x + cosA * length,
                                             y: center.y + sinA * length))
                    ctx.stroke(
                        path,
                        with: .color(VisualizerPalette.mark.opacity(0.35 + Double(mag) * 0.6)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                }
            }
        }
    }
}

// MARK: - Horizontal

private struct HorizontalSpectrum: View {
    let analyzer: SpectrumAnalyzer

    /// Height reserved below the baseline for the reflection stubs. The
    /// prototype draws these starting at the canvas' own bottom edge, where
    /// the browser clips them away entirely — reserving the strip is what
    /// makes the footing it clearly intends actually visible.
    private static let reflectionHeight: CGFloat = 28

    var body: some View {
        let magnitudes = analyzer.magnitudes
        GeometryReader { geo in
            let barCount = max(magnitudes.count, 1)
            let barSpacing: CGFloat = 4
            let barWidth = max(2, (geo.size.width - barSpacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let baselineY = geo.size.height - Self.reflectionHeight

            Canvas { ctx, _ in
                for i in 0..<barCount {
                    let mag = CGFloat(magnitudes[i])
                    let h = max(2, mag * baselineY)
                    let x = CGFloat(i) * (barWidth + barSpacing)

                    ctx.fill(
                        Path(roundedRect: CGRect(x: x, y: baselineY - h, width: barWidth, height: h),
                             cornerRadius: barWidth / 2),
                        with: .color(VisualizerPalette.mark.opacity(0.42 + Double(mag) * 0.53))
                    )
                    ctx.fill(
                        Path(roundedRect: CGRect(x: x, y: baselineY,
                                                 width: barWidth,
                                                 height: min(Self.reflectionHeight, h * 0.35)),
                             cornerRadius: barWidth / 2),
                        with: .color(VisualizerPalette.mark.opacity(0.14))
                    )
                }

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: baselineY))
                baseline.addLine(to: CGPoint(x: geo.size.width, y: baselineY))
                ctx.stroke(baseline, with: .color(Theme.divider), lineWidth: 1)
            }
        }
    }
}

// MARK: - Spectrogram

/// Scrolling stipple spectrogram.
///
/// The history lives in a persistent bitmap used as a horizontal ring buffer:
/// each frame stipples a single fresh column at the write head and the head
/// wraps around, so nothing ever moves. Display then draws that bitmap twice,
/// offset so the newest column lands on the right edge and the seam falls off
/// the left.
///
/// The design prototype instead blits the whole surface one step to the left
/// each frame. That is a full-surface copy per frame on top of the one the
/// display already needs — around 18 MB of memcpy at 60 Hz on a Retina
/// window — which is exactly the sort of steady cost that reads as stutter.
/// The ring buffer produces the identical image for none of it.
private struct SpectrogramStipple: NSViewRepresentable {
    let analyzer: SpectrumAnalyzer
    let palette: HomePalette?

    func makeNSView(context: Context) -> StippleView { StippleView() }

    func updateNSView(_ view: StippleView, context: Context) {
        view.palette = palette
        view.append(analyzer.magnitudes)
    }

    final class StippleView: NSView {
        /// Horizontal advance per frame, in points.
        private static let step: CGFloat = 1.6

        private var buffer: CGContext?
        private var bufferSize: CGSize = .zero
        private var bufferScale: CGFloat = 1
        private var bufferIsDark: Bool = true
        /// Write head, in points from the buffer's left edge.
        private var head: CGFloat = 0
        /// Guards against advancing the scroll on re-renders the analyzer
        /// didn't cause — the chrome overlaid on this view redraws on every
        /// playback-time tick, which would otherwise double the scroll rate.
        private var lastMagnitudes: [Float] = []

        /// The cover's colors, low frequencies to high. Columns already
        /// drawn keep the colors they were drawn in.
        var palette: HomePalette? {
            didSet { if palette != oldValue { rampIsDark = nil } }
        }
        /// Per-row RGB, resolved for the current appearance.
        private var ramp: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        private var rampIsDark: Bool?

        /// Blend the palette's three colors across `rows` bands, bottom to
        /// top; the mark color when there's no palette.
        private func makeRamp(rows: Int, isDark: Bool) {
            let stops: [NSColor] = palette?.nsSeries(3, dark: isDark) ?? [isDark ? .white : .black]
            let rgb = stops.map { color -> (CGFloat, CGFloat, CGFloat) in
                let c = color.usingColorSpace(.deviceRGB) ?? color
                return (c.redComponent, c.greenComponent, c.blueComponent)
            }
            ramp = (0..<rows).map { i in
                guard rgb.count > 1 else { return (rgb[0].0, rgb[0].1, rgb[0].2) }
                let f = CGFloat(i) / CGFloat(max(rows - 1, 1)) * CGFloat(rgb.count - 1)
                let lo = min(Int(f), rgb.count - 2)
                let t = f - CGFloat(lo)
                let a = rgb[lo], b = rgb[lo + 1]
                return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
            }
            rampIsDark = isDark
        }

        /// Stipple one fresh column at the write head, then advance it.
        func append(_ mags: [Float]) {
            guard !mags.isEmpty, bounds.width > 1, bounds.height > 1,
                  mags != lastMagnitudes else { return }
            lastMagnitudes = mags

            let scale = window?.backingScaleFactor ?? 2
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if buffer == nil || bufferSize != bounds.size
                || bufferScale != scale || bufferIsDark != isDark {
                makeBuffer(size: bounds.size, scale: scale, isDark: isDark)
            }
            guard let ctx = buffer else { return }

            let w = bounds.width, h = bounds.height
            head += Self.step
            if head >= w { head -= w }

            // Wipe the strip about to be written, including the part that
            // wraps past the right edge.
            ctx.clear(CGRect(x: head, y: 0, width: Self.step, height: h))
            let overshoot = head + Self.step - w
            if overshoot > 0 {
                ctx.clear(CGRect(x: 0, y: 0, width: overshoot, height: h))
            }

            let rows = mags.count
            let rowHeight = h / CGFloat(rows)
            if rampIsDark != isDark || ramp.count != rows { makeRamp(rows: rows, isDark: isDark) }

            for i in 0..<rows {
                let mag = CGFloat(mags[i])
                guard mag >= 0.05 else { continue }
                // Bin 0 is the lowest frequency and sits at the bottom; the
                // top bins run up to the window's top edge, where the view's
                // mask fades them out.
                let bandTop = CGFloat(i + 1) * rowHeight * 0.97 + 14
                let radius = max(0.6, mag * 1.8)
                let c = ramp[i]
                ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 0.2 + mag * 0.7)
                for _ in 0..<(1 + Int((mag * 4).rounded())) {
                    var dotX = head + CGFloat.random(in: 0..<Self.step)
                    if dotX >= w { dotX -= w }
                    let dotY = bandTop - CGFloat.random(in: 0..<rowHeight)
                    ctx.fillEllipse(in: CGRect(x: dotX - radius, y: dotY - radius,
                                               width: radius * 2, height: radius * 2))
                }
            }
            needsDisplay = true
        }

        private func makeBuffer(size: CGSize, scale: CGFloat, isDark: Bool) {
            let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
            guard pixelWidth > 0, pixelHeight > 0 else { return }
            let ctx = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            ctx?.scaleBy(x: scale, y: scale)
            buffer = ctx
            bufferSize = size
            bufferScale = scale
            bufferIsDark = isDark
            head = 0
        }

        /// Two draws of the same bitmap, shifted so the write head sits at the
        /// right edge; whichever copy covers a given pixel wins.
        override func draw(_ dirtyRect: NSRect) {
            guard let image = buffer?.makeImage(),
                  let ctx = NSGraphicsContext.current?.cgContext else { return }
            let w = bounds.width, h = bounds.height
            let dx = w - (head + Self.step)
            ctx.draw(image, in: CGRect(x: dx, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: dx - w, y: 0, width: w, height: h))
        }
    }
}
