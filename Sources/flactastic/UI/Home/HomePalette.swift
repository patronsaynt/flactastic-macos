import AppKit
import ImageIO
import SwiftUI

/// Colors sampled from the Home hero banner, so the page takes its accent and
/// chart series from whichever artist image is showing. Holds up to four
/// distinct hues, most dominant first. `nil` (no image, or a black-and-white
/// one) means Home stays monochrome.
///
/// Swatches are stored as raw hue/saturation/brightness and resolved per
/// appearance: lifted for the dark theme, deepened for the light one, so text
/// and bars stay legible on either background.
struct HomePalette: Equatable, Sendable {
    struct Swatch: Equatable, Sendable {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    let swatches: [Swatch]

    /// The banner's most dominant color: used for highlighted figures, the
    /// number-one rank and the Fidelidex score.
    var accent: Color { color(swatches[0]) }

    /// `count` series colors. Distinct hues come first; when the banner has
    /// fewer than `count`, the rest are darker steps of those hues.
    func series(_ count: Int) -> [Color] {
        (0..<count).map { idx in
            let base = swatches[idx % swatches.count]
            let step = Double(idx / swatches.count)
            return color(base, dim: step)
        }
    }

    private func color(_ s: Swatch, dim step: Double = 0) -> Color {
        let fade = pow(0.68, step)
        let dark = NSColor(
            hue: s.hue,
            saturation: min(max(s.saturation, 0.45), 0.85),
            brightness: max(s.brightness, 0.78) * fade,
            alpha: 1
        )
        let light = NSColor(
            hue: s.hue,
            saturation: min(max(s.saturation, 0.55), 0.9),
            brightness: min(max(s.brightness, 0.42), 0.58) * (step == 0 ? 1 : 0.6 + 0.4 * fade),
            alpha: 1
        )
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Extraction

    /// Downsample the image, bin colored pixels by hue, and keep up to four
    /// well-separated hue peaks. Near-black, near-white and gray pixels are
    /// ignored; if too little of the image is colored, returns nil.
    static func extract(from data: Data) -> HomePalette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }

        let w = 48, h = 48
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))

        struct Bin { var weight = 0.0, x = 0.0, y = 0.0, sat = 0.0, bright = 0.0 }
        let binCount = 24
        var bins = [Bin](repeating: Bin(), count: binCount)
        var colored = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
            guard maxC >= 0.15, sat >= 0.2, !(maxC > 0.95 && sat < 0.3) else { continue }
            colored += 1

            var hue = 0.0
            let d = maxC - minC
            if maxC == r { hue = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / d + 2 }
            else { hue = (r - g) / d + 4 }
            hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)

            let weight = sat * (0.4 + 0.6 * maxC)
            let angle = hue * 2 * .pi
            let idx = min(Int(hue * Double(binCount)), binCount - 1)
            bins[idx].weight += weight
            bins[idx].x += cos(angle) * weight
            bins[idx].y += sin(angle) * weight
            bins[idx].sat += sat * weight
            bins[idx].bright += maxC * weight
        }

        // A mostly gray photo has no scheme to offer.
        guard Double(colored) / Double(w * h) >= 0.04 else { return nil }

        let ranked = bins.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard let topWeight = ranked.first?.weight else { return nil }

        var swatches: [Swatch] = []
        for bin in ranked where bin.weight >= topWeight * 0.08 {
            var hue = atan2(bin.y, bin.x) / (2 * .pi)
            if hue < 0 { hue += 1 }
            let separated = swatches.allSatisfy { other in
                let delta = abs(other.hue - hue)
                return min(delta, 1 - delta) >= 35.0 / 360
            }
            guard separated else { continue }
            swatches.append(Swatch(
                hue: hue,
                saturation: bin.sat / bin.weight,
                brightness: bin.bright / bin.weight
            ))
            if swatches.count == 4 { break }
        }
        return swatches.isEmpty ? nil : HomePalette(swatches: swatches)
    }
}
