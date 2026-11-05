import AppKit
import ImageIO

/// Covers leave the app (to macOS Now Playing, to a cast device) at no more
/// than 1000 px, while the music files keep them at full resolution.
enum CoverExport {
    static let maxPixel = 1000

    /// A JPEG no larger than `maxPixel` on its long edge. A JPEG already that
    /// small is passed through untouched; anything else (a bigger JPEG, any
    /// PNG) is downsampled and encoded as JPEG to keep it light. Nil if the
    /// data isn't an image.
    static func jpeg(_ data: Data, maxPixel: Int = maxPixel) -> Data? {
        if CoverFormat(data) == .jpeg, let size = pixelSize(data), max(size.width, size.height) <= maxPixel {
            return data
        }
        guard let small = PrerenderedImage.downsampled(data, maxPixel: maxPixel) else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// The image itself, at most `maxPixel` on its long edge.
    static func image(_ data: Data, maxPixel: Int = maxPixel) -> NSImage? {
        guard let small = PrerenderedImage.downsampled(data, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }

    /// Pixel size from the file's header, without decoding it.
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}
