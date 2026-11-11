import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Logo images the person adds for artists and labels, shown on the rack's
/// spines in place of the printed name or the label's initials. Each is
/// copied in (downsampled to a sensible size, as PNG) so it survives the
/// original moving, and decoded once per session.
enum SpineLogoStore {
    static var folder: URL { LibraryDataFolder.url.appendingPathComponent("SpineLogos", isDirectory: true) }

    /// Forgets decoded logos (another library's are a different set).
    static func clearCache() { cache.removeAllObjects() }

    /// Copies the image at `url` into the store and returns its file name,
    /// or nil when it isn't an image that can be read.
    static func importImage(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let image = PrerenderedImage.downsampled(data, maxPixel: 600),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        LibraryDataFolder.didChange()
        return name
    }

    /// Deletes a stored logo nothing refers to any more.
    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        cache.removeObject(forKey: name as NSString)
        LibraryDataFolder.didChange()
    }

    /// `NSCache` is internally thread-safe.
    private nonisolated(unsafe) static let cache = NSCache<NSString, Logo>()

    /// A decoded logo, and whether it has transparency: a cut-out logo is
    /// printed in the spine's ink colour, a solid one drawn as it is.
    final class Logo: @unchecked Sendable {
        let image: NSImage
        let isCutOut: Bool
        init(image: NSImage, isCutOut: Bool) { self.image = image; self.isCutOut = isCutOut }
    }

    static func logo(_ name: String) -> Logo? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        let url = folder.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let alpha = cg.alphaInfo
        let cutOut = !(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst) && hasTransparency(cg)
        let logo = Logo(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), isCutOut: cutOut)
        cache.setObject(logo, forKey: name as NSString)
        return logo
    }

    /// True when any of a coarse sample of pixels is see-through.
    private static func hasTransparency(_ image: CGImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }
}

/// Real spine scans that came with an album: an image named like
/// "spine.jpg" in the album's folder. Found and cut to the spine's size once,
/// off the main thread.
final class SpineScanCache: @unchecked Sendable {
    static let shared = SpineScanCache()

    private final class Box { let image: NSImage?; init(_ image: NSImage?) { self.image = image } }
    /// `NSCache` is internally thread-safe; that is the whole of the
    /// `@unchecked Sendable` claim. Misses are cached too, so a folder with no
    /// scan is looked at once.
    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 400
    }

    /// The scan file in `folder`, if there is one: an image whose name, less
    /// its extension, is "spine" or contains it as a word (Spine, CD Spine,
    /// spine-front…).
    static func scanFile(in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let images: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "webp", "heic"]
        let match = names.sorted().first { name in
            let ext = (name as NSString).pathExtension.lowercased()
            let stem = (name as NSString).deletingPathExtension.lowercased()
            guard images.contains(ext) else { return false }
            return stem == "spine" || stem.split(whereSeparator: { !$0.isLetter }).contains("spine")
        }
        return match.map { folder.appendingPathComponent($0) }
    }

    func cached(folder: URL, pixelHeight: Int) -> NSImage?? {
        cache.object(forKey: Self.key(folder, pixelHeight) as NSString).map { $0.image }
    }

    /// The last scan decoded from this folder at any size, so a spine drawn
    /// at a new size shows it at once while its own is decoded.
    func anySize(folder: URL) -> NSImage? {
        latest.object(forKey: folder.path as NSString)?.image
    }

    private let latest = NSCache<NSString, Box>()

    /// The scan in `folder`, upright (a sideways scan is turned so its text
    /// reads top to bottom), decoded at the spine's height. Nil when there's
    /// none.
    func scan(in folder: URL, pixelHeight: Int) async -> NSImage? {
        if let hit = cached(folder: folder, pixelHeight: pixelHeight) { return hit }
        let key = Self.key(folder, pixelHeight)
        let result = await Task.detached(priority: .utility) { [cache] in
            var image: NSImage?
            if let file = Self.scanFile(in: folder), let data = try? Data(contentsOf: file),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
               let decoded = PrerenderedImage.downsampled(data, maxPixel: pixelHeight) {
                image = Self.upright(decoded, sideways: w > h)
            }
            cache.setObject(Box(image), forKey: key as NSString)
            return image
        }.value
        if let result { latest.setObject(Box(result), forKey: folder.path as NSString) }
        return result
    }

    private static func key(_ folder: URL, _ height: Int) -> String { "\(folder.path)|\(height)" }

    /// Turns a landscape scan a quarter turn clockwise.
    private static func upright(_ image: CGImage, sideways: Bool) -> NSImage? {
        guard sideways else { return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        let w = image.height, h = image.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: w, height: h)) }
    }
}
