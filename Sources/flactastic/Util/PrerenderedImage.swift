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

    func image(for data: Data?, id: String) async -> ArtworkImageCache.ImageBox {
        if let hit = cached(id: id) { return .init(image: hit) }
        guard let data else { return .init(image: nil) }
        return await Task.detached(priority: .userInitiated) { [cache] in
            // A tiny source is plenty: the backdrop is blurred past any detail.
            let image = PrerenderedImage.nsImage(PrerenderedImage.blurred(data, maxPixel: 96, radius: 5))
            if let image { cache.setObject(image, forKey: id as NSString) }
            return ArtworkImageCache.ImageBox(image: image)
        }.value
    }
}
