import AppKit
import CoreImage
import ImageIO

/// Off-main image preparation for large decorative images (the artist
/// banner, the spotlight backdrop). Decoding at display size and baking heavy
/// blurs into a small bitmap once is far cheaper than SwiftUI decoding the
/// full-size image and running a live `blur` every frame the page scrolls.
enum PrerenderedImage {
    /// Shared Core Image context; `CIContext` is safe to use from any thread.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Decode `data` downsampled so its long edge is at most `maxPixel`.
    static func downsampled(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// Downsample, then Gaussian-blur by `radius` pixels of the downsampled
    /// image. Edges are clamped first, so the result stays opaque to the
    /// border instead of fading out the way a live SwiftUI blur does.
    static func blurred(_ data: Data, maxPixel: Int, radius: Double) -> CGImage? {
        guard let small = downsampled(data, maxPixel: maxPixel) else { return nil }
        let input = CIImage(cgImage: small)
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: input.extent)
        return context.createCGImage(output, from: input.extent)
    }

    /// Blur radius in pixels of a `maxPixel` image that matches a SwiftUI
    /// blur of `points` on an image drawn about `displayWidth` points wide.
    static func pixelRadius(points: Double, maxPixel: Int, displayWidth: Double = 1440) -> Double {
        points * Double(maxPixel) / displayWidth
    }

    static func nsImage(_ cgImage: CGImage?) -> NSImage? {
        cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

/// Pre-blurred album covers for the artist page's spotlight backdrop, kept
/// for the session so switching between albums is instant.
final class BlurredArtworkCache: @unchecked Sendable {
    static let shared = BlurredArtworkCache()

    /// `NSCache` is internally thread-safe; that is the whole of the
    /// `@unchecked Sendable` claim.
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 64
    }

    func cached(id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// The defaults suit a backdrop blurred past any detail, where a tiny
    /// source is plenty; pass a larger `maxPixel` and gentler `radius` for
    /// an image that should still read as a picture.
    func image(for data: Data?, id: String, maxPixel: Int = 96, radius: Double = 5) async -> ArtworkImageCache.ImageBox {
        if let hit = cached(id: id) { return .init(image: hit) }
        guard let data else { return .init(image: nil) }
        return await Task.detached(priority: .userInitiated) { [cache] in
            let image = PrerenderedImage.nsImage(PrerenderedImage.blurred(data, maxPixel: maxPixel, radius: radius))
            if let image { cache.setObject(image, forKey: id as NSString) }
            return ArtworkImageCache.ImageBox(image: image)
        }.value
    }
}

/// Sharp slices of album covers for the Albums rack's spines: the cover
/// decoded at the spine's height, one spine-wide strip cut from it, with any
/// ageing (faded, warmed colour) baked in. Made once off the main thread and
/// kept, so scrolling the rack runs no image work at all.
final class SpineArtCache: @unchecked Sendable {
    static let shared = SpineArtCache()

    struct Art: Sendable {
        let image: NSImage?
        /// Mean brightness (0…1) of the slice's top and bottom fifths, for
        /// type printed straight onto the art there.
        let topLuminance: Double
        let bottomLuminance: Double
    }

    private final class Box { let art: Art; init(_ art: Art) { self.art = art } }

    /// `NSCache` is internally thread-safe; that is the whole of the
    /// `@unchecked Sendable` claim. Each slice is small (a spine's width by
    /// its height), so a few hundred cover a long shelf.
    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 300
    }

    static func key(data: Data, slice: Double, pixelSize: CGSize, age: Double) -> String {
        "\(sizeFreeKey(data: data, slice: slice, age: age))|\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }

    /// The same slice at any size.
    static func sizeFreeKey(data: Data, slice: Double, age: Double) -> String {
        "\(ArtworkImageCache.contentID(for: data))|\(Int(slice * 1000))|\(Int(age * 20))"
    }

    func cached(key: String) -> Art? {
        cache.object(forKey: key as NSString)?.art
    }

    /// The last slice cut for this cover, position and age, whatever its
    /// size: a spine drawn at a new size (the case lifted off the shelf)
    /// shows it straight away while its own is cut, instead of drawing blank.
    func anySize(_ sizeFreeKey: String) -> Art? {
        latest.object(forKey: sizeFreeKey as NSString)?.art
    }

    private let latest = NSCache<NSString, Box>()

    func art(for data: Data, key: String, slice: Double, pixelSize: CGSize, age: Double) async -> Art {
        if let hit = cached(key: key) { return hit }
        let result = await Task.detached(priority: .userInitiated) { [cache] in
            let art = Self.render(data, slice: slice, pixelSize: pixelSize, age: age)
            cache.setObject(Box(art), forKey: key as NSString)
            return art
        }.value
        latest.setObject(Box(result), forKey: Self.sizeFreeKey(data: data, slice: slice, age: age) as NSString)
        return result
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func render(_ data: Data, slice: Double, pixelSize: CGSize, age: Double) -> Art {
        let blank = Art(image: nil, topLuminance: 0.2, bottomLuminance: 0.2)
        let height = max(1, Int(pixelSize.height)), width = max(1, Int(pixelSize.width))
        guard let cover = PrerenderedImage.downsampled(data, maxPixel: height) else { return blank }
        // Scale the cover to the spine's height, then cut the slice.
        let scale = CGFloat(height) / CGFloat(cover.height)
        let coverWidth = CGFloat(cover.width) * scale
        let x = (coverWidth - CGFloat(width)) * CGFloat(min(max(slice, 0), 1))
        var image = CIImage(cgImage: cover)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -max(0, x), y: 0))
        if age > 0 {
            image = image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - age * 0.35])
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: age * 0.22])
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cg = context.createCGImage(image, from: rect) else { return blank }
        return Art(
            image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)),
            topLuminance: luminance(cg, top: true),
            bottomLuminance: luminance(cg, top: false)
        )
    }

    /// Mean brightness of the top or bottom fifth, drawn down to one grey pixel.
    private static func luminance(_ image: CGImage, top: Bool) -> Double {
        let band = max(1, image.height / 5)
        let rect = CGRect(x: 0, y: top ? 0 : image.height - band, width: image.width, height: band)
        guard let part = image.cropping(to: rect) else { return 0.2 }
        var pixel: UInt8 = 0
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0.2 }
        ctx.interpolationQuality = .medium
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(pixel) / 255
    }
}
