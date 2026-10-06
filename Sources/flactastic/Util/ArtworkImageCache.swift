import AppKit
import ImageIO

/// Decodes and caches downsampled artwork thumbnails for grid/list cells.
///
/// Embedded album art is often a multi-MB JPEG; decoding it at full
/// resolution on every cell instantiation (which lazy grids/lists do
/// repeatedly while scrolling) is the dominant cost of scroll jank.
/// `CGImageSourceCreateThumbnailAtIndex` lets ImageIO downsample *during*
/// decode instead of materializing the full bitmap and letting SwiftUI
/// scale it down afterward.
///
/// Two layers back this:
///  - An `NSCache` (in memory, this session only) — a dictionary lookup for
///    repeat visits to the same cell.
///  - A small JPEG on disk under Caches/ (persists across launches) — so a
///    cold app start doesn't have to re-decode every embedded image from
///    scratch; it just re-reads a pre-shrunk thumbnail, which is cheap.
///
/// `prewarm` lets a caller decode (and disk-cache) thumbnails ahead of time
/// — e.g. right after a library scan completes — so the first scroll
/// through a grid hits a warm cache instead of paying decode cost live.
///
/// Backed by `NSCache`, which is internally thread-safe, so this can be
/// called synchronously from any thread without additional locking — the
/// `@unchecked Sendable` here is scoped to that single, audited guarantee.
final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let diskDirectory: URL
    /// Disk writes happen off the calling thread so a cache miss during
    /// live scrolling never blocks on file I/O — the decoded image is
    /// already in the in-memory cache and returned before this fires.
    private let diskWriteQueue = DispatchQueue(label: "flactastic.artworkimagecache.diskwrite", qos: .utility)

    private init() {
        // Soft ceiling on decoded RGBA bytes held in memory. Each album
        // caches multiple sizes (grid/list/detail) and tracks are cached
        // individually too, so this adds up fast — at ~1.2MB per album for
        // three sizes, a budget in the tens of MB starts evicting (and
        // forcing redecodes) on libraries as small as a few dozen albums,
        // which defeats the cache the moment you scroll past it once. 320MB
        // comfortably covers thousands of thumbnails; NSCache's automatic
        // eviction under genuine system memory pressure is the real
        // backstop beyond that, not this number.
        cache.totalCostLimit = 320 * 1024 * 1024

        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        diskDirectory = base.appendingPathComponent("FLACtastic/ArtworkThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Returns a cached or freshly-decoded thumbnail for `data`, downsampled
    /// to fit `pointSize` at `scale`. `id` must be stable and unique per
    /// artwork source (e.g. `"album:<Album.id>"`, `"track:<Track.id>"`) —
    /// callers should prefix by kind so different id spaces can't collide.
    /// Returns `nil` if `data` is nil, empty, or undecodable.
    func thumbnail(for data: Data?, id: String, pointSize: CGFloat, scale: CGFloat = 2) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }

        let key = Self.cacheKey(id: id, pointSize: pointSize, scale: scale)
        let nsKey = key as NSString

        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        if let onDisk = loadFromDisk(key: key) {
            cache.setObject(onDisk, forKey: nsKey, cost: Self.cost(of: onDisk))
            return onDisk
        }

        let pixelSize = Self.pixelSize(pointSize: pointSize, scale: scale)
        guard let image = Self.decodeThumbnail(data: data, maxPixelSize: pixelSize) else {
            return nil
        }

        cache.setObject(image, forKey: nsKey, cost: Self.cost(of: image))
        diskWriteQueue.async { [diskDirectory] in
            Self.saveToDisk(image, key: key, directory: diskDirectory)
        }
        return image
    }

    /// Memory-cache-only lookup — no disk read, no decode, no I/O of any
    /// kind. The fast path for view bodies: on a hit, rendering is identical
    /// to (and as cheap as) a dictionary lookup; on nil the caller should
    /// show its placeholder and decode via `thumbnailAsync` instead of
    /// blocking the main thread mid-scroll.
    func cachedThumbnail(id: String, pointSize: CGFloat, scale: CGFloat = 2) -> NSImage? {
        cache.object(forKey: Self.cacheKey(id: id, pointSize: pointSize, scale: scale) as NSString)
    }

    /// `NSImage` isn't formally `Sendable`, but decoded thumbnails are
    /// immutable after creation and only ever read — the same audited
    /// invariant that lets this class hand them out of `NSCache` from any
    /// thread. This box carries one across an isolation boundary.
    struct ImageBox: @unchecked Sendable {
        let image: NSImage?
    }

    /// Async variant of `thumbnail(for:id:pointSize:scale:)` for view-body
    /// cache misses: performs the disk read / decode on a background task so
    /// the main thread never pays it during scrolling.
    func thumbnailAsync(for data: Data?, id: String, pointSize: CGFloat, scale: CGFloat = 2) async -> ImageBox {
        await Task.detached(priority: .userInitiated) { [self] in
            ImageBox(image: thumbnail(for: data, id: id, pointSize: pointSize, scale: scale))
        }.value
    }

    /// Decodes (and disk-/memory-caches) a thumbnail without a caller
    /// needing the result. Intended for batch warm-up — e.g. right after a
    /// library scan completes, before the user has scrolled anything — so
    /// the corresponding `thumbnail(for:id:pointSize:scale:)` calls made
    /// while actually rendering hit a warm cache instead of decoding live.
    /// Safe to call from a background task; does its own decode + disk
    /// write synchronously on the calling thread, so callers should already
    /// be off the main thread for batch use.
    func prewarm(data: Data?, id: String, pointSize: CGFloat, scale: CGFloat = 2) {
        guard let data, !data.isEmpty else { return }

        let key = Self.cacheKey(id: id, pointSize: pointSize, scale: scale)
        let nsKey = key as NSString
        guard cache.object(forKey: nsKey) == nil else { return }

        if let onDisk = loadFromDisk(key: key) {
            cache.setObject(onDisk, forKey: nsKey, cost: Self.cost(of: onDisk))
            return
        }

        let pixelSize = Self.pixelSize(pointSize: pointSize, scale: scale)
        guard let image = Self.decodeThumbnail(data: data, maxPixelSize: pixelSize) else { return }
        cache.setObject(image, forKey: nsKey, cost: Self.cost(of: image))
        Self.saveToDisk(image, key: key, directory: diskDirectory)
    }

    /// Removes all cached sizes for `id`, in memory and on disk. Call this
    /// wherever the underlying artwork can change (album/track metadata
    /// edits) so stale thumbnails don't linger after a save.
    func invalidate(id: String, pointSizes: [CGFloat] = ArtworkImageCache.invalidationSizes, scale: CGFloat = 2) {
        for size in pointSizes {
            let key = Self.cacheKey(id: id, pointSize: size, scale: scale)
            cache.removeObject(forKey: key as NSString)
            try? fileManager.removeItem(at: diskURL(forKey: key))
        }
    }

    // MARK: - Size buckets

    /// Point sizes the grids and lists have always used; kept exact so their
    /// cached thumbnails stay valid.
    private static let standardSizes: Set<CGFloat> = [36, 48, 180, 200, 280]

    /// The size to decode for artwork drawn at `displaySize`. Standard and
    /// small sizes pass through; anything else rounds up to a 64pt step, so
    /// layouts that size covers from the window width (the artist page) share
    /// a handful of cache entries instead of decoding again on every resize.
    /// Rounding up means the image is only ever drawn at or below its pixel
    /// size, never stretched.
    static func decodePointSize(for displaySize: CGFloat) -> CGFloat {
        if displaySize <= 64 || standardSizes.contains(displaySize) { return displaySize }
        return min((displaySize / 64).rounded(.up) * 64, 1024)
    }

    /// Every size `invalidate` clears: the standard sizes plus each bucket.
    static let invalidationSizes: [CGFloat] =
        Array(standardSizes).sorted() + stride(from: 128, through: 1024, by: 64).map { CGFloat($0) }

    // MARK: - Keys

    /// Content-derived cache id: byte count plus a few sampled bytes. Cheap
    /// (no full-buffer hash), stable across launches (unlike `Data.hashValue`,
    /// which is salted per process), and identical blobs share one id — so
    /// every track row showing its album's cover resolves to the same cached
    /// thumbnail instead of decoding per-track duplicates.
    static func contentID(for data: Data) -> String {
        let count = data.count
        guard count > 0 else { return "data:0" }
        let a = data[data.startIndex]
        let b = data[data.index(data.startIndex, offsetBy: count / 2)]
        let c = data[data.index(before: data.endIndex)]
        return "data:\(count)-\(a)-\(b)-\(c)"
    }

    private static func pixelSize(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((pointSize * scale).rounded(.up)))
    }

    private static func cacheKey(id: String, pointSize: CGFloat, scale: CGFloat) -> String {
        "\(id)#\(pixelSize(pointSize: pointSize, scale: scale))"
    }

    private static func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    // MARK: - Disk

    private func diskURL(forKey key: String) -> URL {
        diskDirectory.appendingPathComponent(Self.stableHash(key) + ".jpg")
    }

    private func loadFromDisk(key: String) -> NSImage? {
        guard let data = try? Data(contentsOf: diskURL(forKey: key)) else { return nil }
        return NSImage(data: data)
    }

    private static func saveToDisk(_ image: NSImage, key: String, directory: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        let url = directory.appendingPathComponent(stableHash(key) + ".jpg")
        try? jpeg.write(to: url, options: .atomic)
    }

    /// Swift's built-in `String.hashValue` is salted with a random per-
    /// process seed (by design, for DoS resistance), so it can't be used to
    /// derive a filename that needs to resolve to the same path across app
    /// launches. This is a plain FNV-1a hash over the key's UTF-8 bytes —
    /// deterministic across runs, which is all a cache-key-to-filename
    /// mapping needs.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash.multipliedReportingOverflow(by: 0x100000001b3).partialValue
        }
        return String(hash, radix: 16)
    }

    private static func decodeThumbnail(data: Data, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }
}
