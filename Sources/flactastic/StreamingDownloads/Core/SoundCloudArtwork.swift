import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds the best JPEG for a SoundCloud cover.
///
/// SoundCloud serves every rendition of an artwork from one CDN path that
/// differs only in a size suffix (`…-large.jpg` is 100 px, `…-t500x500.jpg`,
/// `…-t1080x1080.jpg`, `…-t3000x3000.jpg`, `…-original.jpg`). Lucida's metadata
/// hands back one of the small ones, so downloads were tagged with thumbnail-
/// sized covers.
///
/// The fixed `tNxN` sizes are *upscaled* when the upload is smaller than
/// requested, so `-original` — the file the artist actually uploaded — is the
/// true highest quality. It isn't always a JPEG, though, so non-JPEG originals
/// are re-encoded to JPEG at their native resolution.
enum SoundCloudArtwork {
    /// Largest edge we embed. Matches SoundCloud's biggest rendition and keeps
    /// a huge original upload from bloating every downloaded file.
    static let maxPixelSize = 3000

    /// Fixed renditions, best first, used when no original is available.
    private static let fixedSizes = ["t3000x3000", "t1080x1080", "t500x500"]

    /// `artworks-<id>-<size>.<ext>` / `avatars-<id>-<size>.<ext>`. The id may
    /// itself contain hyphens; the size is always the last segment.
    private static let filenamePattern =
        try! NSRegularExpression(pattern: #"^((?:artworks|avatars)-.+)-[a-z0-9]+\.(?:jpe?g|png|gif)$"#,
                                 options: [.caseInsensitive])

    static func isArtworkURL(_ url: URL) -> Bool {
        stem(of: url) != nil
    }

    /// Renditions to try, best first. Originals come first (`.jpg` and `.png`,
    /// since the original keeps its upload format); `nil` if `url` isn't a
    /// SoundCloud artwork URL.
    static func candidates(for url: URL) -> (originals: [URL], fixed: [URL])? {
        guard let stem = stem(of: url) else { return nil }
        let dir = url.deletingLastPathComponent()
        let originals = ["jpg", "png"].map { dir.appendingPathComponent("\(stem)-original.\($0)") }
        let fixed = fixedSizes.map { dir.appendingPathComponent("\(stem)-\($0).jpg") }
        return (originals, fixed)
    }

    /// Download the best rendition as JPEG data, or `nil` if `url` isn't a
    /// SoundCloud artwork or nothing could be fetched.
    static func fetchBestJPEG(from url: URL, session: URLSession) async -> Data? {
        guard let (originals, fixed) = candidates(for: url) else { return nil }
        for candidate in originals + fixed + [url] {
            guard let data = await fetch(candidate, session: session),
                  let jpeg = jpegData(from: data) else { continue }
            return jpeg
        }
        return nil
    }

    /// Returns `data` unchanged when it's already a JPEG within
    /// `maxPixelSize`; otherwise re-encodes it as a high-quality JPEG,
    /// downscaling only if it's larger than `maxPixelSize`. `nil` if `data`
    /// isn't a decodable image.
    static func jpegData(from data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }

        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        let fits = max(width, height) <= maxPixelSize
        if isJPEG && fits { return data }

        let image: CGImage?
        if fits {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        }
        guard let image else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Helpers

    private static func stem(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("sndcdn.com") else { return nil }
        let name = url.lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        guard let m = filenamePattern.firstMatch(in: name, range: range),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return String(name[r])
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return nil }
        return data
    }
}
