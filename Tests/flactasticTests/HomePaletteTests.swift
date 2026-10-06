import AppKit
import Testing
@testable import flactastic

/// PNG data for a 64×64 image filled by `paint`.
private func png(_ paint: (CGContext) -> Void) -> Data {
    let ctx = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    paint(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

private func hueDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b)
    return min(d, 1 - d)
}

@Test func paletteFindsDominantHueFirst() {
    let data = png { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))   // blue, larger
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))   // red
        ctx.fill(CGRect(x: 0, y: 40, width: 64, height: 24))
    }
    let palette = HomePalette.extract(from: data)
    #expect(palette?.swatches.count == 2)
    #expect(hueDistance(palette!.swatches[0].hue, 0.62) < 0.05)
    #expect(hueDistance(palette!.swatches[1].hue, 0.02) < 0.05)
}

@Test func paletteIsNilForGrayImages() {
    let data = png { ctx in
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
    }
    #expect(HomePalette.extract(from: data) == nil)
}

@Test func paletteSeriesRepeatsHuesWhenShort() {
    let palette = HomePalette(swatches: [.init(hue: 0.5, saturation: 0.8, brightness: 0.8)])
    #expect(palette.series(4).count == 4)
}

@Test func paletteIgnoresGrayButKeepsSmallColorPatch() {
    let data = png { ctx in
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.8, blue: 0.3, alpha: 1))  // green, ~10%
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 7))
    }
    let palette = HomePalette.extract(from: data)
    #expect(palette?.swatches.count == 1)
    #expect(hueDistance(palette!.swatches[0].hue, 0.37) < 0.05)
}
