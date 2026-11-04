import AppKit
import QuartzCore
import SwiftUI

/// The FLACtastic mark as a loading animation, in the app's ink (white in
/// dark, black in light). Three styles: one picked in UI for nerds, or a
/// random one each launch (the default); sized by the mark's height, so it
/// works from a panel (40pt) to a full-screen wait. Holds still with Reduce
/// Motion.
///
/// Drawn with Core Animation rather than redrawn by SwiftUI each frame: the
/// loader shows exactly while the app is busiest (the library loading on the
/// main thread), and a layer animation, once committed, is played by the
/// window server on its own clock, so it stays smooth however busy the app
/// is. SwiftUI only sets it up and swaps it when the style or size changes.
struct BrandLoader: View {
    var height: CGFloat = 72
    var style: LoadingAnimation = UIStyle.shared.resolvedLoadingAnimation
    /// A soft glow around the moving ink, for a loader alone on a screen.
    var bloom = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let image = BrandMark.image {
            let width = height * image.size.width / max(image.size.height, 1)
            BrandLoaderLayers(style: style, isStill: reduceMotion, bloom: bloom)
                .frame(width: width, height: height)
                .accessibilityElement()
                .accessibilityLabel("Loading")
        }
    }
}

private struct BrandLoaderLayers: NSViewRepresentable {
    let style: LoadingAnimation
    let isStill: Bool
    let bloom: Bool

    func makeNSView(context: Context) -> BrandLoaderView { BrandLoaderView() }

    func updateNSView(_ view: BrandLoaderView, context: Context) {
        view.configure(style: style, isStill: isStill, bloom: bloom)
    }
}

/// The layer tree: the mark as a mask over a faint ink fill and the style's
/// moving layers, plus (for the laser) the reading line outside the mask.
/// Every animation is relative to the view's size, so it's rebuilt when the
/// size changes and otherwise left running untouched.
final class BrandLoaderView: NSView {
    private var style: LoadingAnimation = .spectrum
    private var isStill = false
    private var bloom = false
    private var builtSize: CGSize = .zero

    /// Unmasked, so its shadow follows the masked, moving ink: the bloom.
    private let glow = CALayer()
    private let content = CALayer()
    private let markMask = CALayer()
    private let beam = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        content.mask = markMask
        markMask.contentsGravity = .resizeAspect
        markMask.contents = BrandMark.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        glow.addSublayer(content)
        layer?.addSublayer(glow)
        layer?.addSublayer(beam)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Core Animation's own coordinates throughout (origin at the bottom
    // left), so the mark image in the mask isn't drawn upside down.

    func configure(style: LoadingAnimation, isStill: Bool, bloom: Bool) {
        guard style != self.style || isStill != self.isStill || bloom != self.bloom || builtSize == .zero else { return }
        self.style = style
        self.isStill = isStill
        self.bloom = bloom
        rebuild()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    /// The app's primary ink as this view's appearance resolves it.
    private var ink: CGColor {
        var color = NSColor.white.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(Theme.textPrimary).cgColor
        }
        return color
    }

    private func rebuild() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        builtSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        glow.frame = bounds
        content.frame = glow.bounds
        markMask.frame = content.bounds
        // The bloom: a wide, soft glow of the ink around whatever is lit,
        // gentler in light mode, where it reads as a soft shadow instead.
        glow.shadowColor = ink
        glow.shadowOffset = .zero
        glow.shadowRadius = size.height * 0.3
        glow.shadowOpacity = bloom ? (isDark ? 0.75 : 0.3) : 0
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        beam.removeAllAnimations()
        beam.isHidden = true

        let dim = CALayer()
        dim.frame = content.bounds
        dim.backgroundColor = ink.copy(alpha: 0.18)
        content.addSublayer(dim)

        switch style {
        case .sheen: buildSheen(size)
        case .laser: buildLaser(size)
        case .spectrum: buildSpectrum(size)
        }
    }

    // MARK: Styles

    /// A band of light sweeps across the faint mark, as across a clear case.
    private func buildSheen(_ size: CGSize) {
        let band = CAGradientLayer()
        let ink = ink
        // Five stops rather than three, so the band has no hard shoulders.
        band.colors = [ink.copy(alpha: 0)!, ink.copy(alpha: 0.35)!, ink, ink.copy(alpha: 0.35)!, ink.copy(alpha: 0)!]
        band.locations = [0, 0.3, 0.5, 0.7, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let width = size.width * 0.5
        band.bounds = CGRect(x: 0, y: 0, width: width, height: size.height * 2)
        band.position = CGPoint(x: -width / 2, y: size.height / 2)
        band.setAffineTransform(CGAffineTransform(rotationAngle: 15 * .pi / 180))
        content.addSublayer(band)

        guard !isStill else {
            band.position.x = size.width * 0.45
            return
        }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width / 2
        sweep.toValue = size.width + width / 2
        sweep.duration = 1.9
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "sweep")
    }

    /// A reading line passes down the mark and back, drawing it as it goes.
    private func buildLaser(_ size: CGSize) {
        // Solid where it's been read, feathering into the line's edge.
        let drawn = CAGradientLayer()
        drawn.colors = [ink, ink, ink.copy(alpha: 0.35)!]
        drawn.locations = [0, 0.86, 1]
        drawn.startPoint = CGPoint(x: 0.5, y: 1)
        drawn.endPoint = CGPoint(x: 0.5, y: 0)
        drawn.anchorPoint = CGPoint(x: 0.5, y: 1)
        drawn.bounds = CGRect(origin: .zero, size: size)
        drawn.position = CGPoint(x: size.width / 2, y: size.height)
        content.addSublayer(drawn)

        // The line runs a little past the mark either side, outside the mask.
        let thickness = max(1.5, size.height * 0.03)
        beam.isHidden = false
        beam.backgroundColor = ink
        beam.cornerRadius = thickness / 2
        beam.bounds = CGRect(x: 0, y: 0, width: size.width * 1.24, height: thickness)
        beam.position = CGPoint(x: size.width / 2, y: size.height)
        beam.shadowColor = ink
        beam.shadowOpacity = 0.6
        beam.shadowRadius = size.height * 0.12
        beam.shadowOffset = .zero

        guard !isStill else {
            drawn.transform = CATransform3DMakeScale(1, 0.6, 1)
            beam.position.y = size.height * 0.4
            return
        }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let fill = CABasicAnimation(keyPath: "transform.scale.y")
        fill.fromValue = 0.001
        fill.toValue = 1
        let line = CABasicAnimation(keyPath: "position.y")
        line.fromValue = size.height
        line.toValue = 0
        for animation in [fill, line] {
            animation.duration = 2.2
            animation.timingFunction = timing
            animation.autoreverses = true
            animation.repeatCount = .infinity
        }
        drawn.add(fill, forKey: "draw")
        beam.add(line, forKey: "scan")
    }

    /// The mark as a row of meter bars, each at its own height.
    private func buildSpectrum(_ size: CGSize) {
        let count = 16
        let gap = max(1, size.width * 0.008)
        let barWidth = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let period = 1.8
        let samples = 36
        let ink = ink
        for i in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = ink
            bar.cornerRadius = barWidth * 0.3
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: size.height)
            bar.position = CGPoint(x: CGFloat(i) * (barWidth + gap) + barWidth / 2, y: 0)
            content.addSublayer(bar)

            // Two waves at different speeds, offset bar by bar: sampled over
            // one period (the slower wave's) and looped by the window server.
            func level(_ t: Double) -> Double {
                let wave = 0.5 + 0.5 * sin(t * 2 * .pi / period + Double(i) * 0.82)
                let wobble = 0.5 + 0.5 * sin(t * 2 * .pi / (period / 2) + Double(i) * 1.7)
                return 0.22 + 0.55 * wave + 0.18 * wobble
            }
            guard !isStill else {
                bar.transform = CATransform3DMakeScale(1, level(0.4), 1)
                continue
            }
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
            bounce.values = (0...samples).map { level(Double($0) / Double(samples) * period) }
            bounce.duration = period
            bounce.calculationMode = .cubic
            bounce.repeatCount = .infinity
            bar.add(bounce, forKey: "bounce")
        }
    }
}

/// Which way the FLACtastic mark animates while something loads.
enum LoadingAnimation: String, CaseIterable, Identifiable {
    case sheen, laser, spectrum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sheen: "Sheen"
        case .laser: "Laser"
        case .spectrum: "Spectrum"
        }
    }
}
