import SwiftUI

struct ArtworkView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.displayScale) private var displayScale

    let data: Data?
    var size: CGFloat = 280
    /// Stable identity for cache keying (e.g. `"album:<Album.id>"`,
    /// `"track:<Track.id>"`). Falls back to a content-derived key if
    /// omitted, which still works but caches less efficiently across
    /// re-renders.
    var id: String? = nil
    /// When `true`, bypasses the downsampling cache and decodes `data` at
    /// its original resolution — used for the tap-to-zoom artwork overlay,
    /// where the user explicitly wants the true source image rather than a
    /// thumbnail sized for a grid cell.
    var fullResolution: Bool = false
    /// `false` for callers that paint their own shadow (the album shelf), so
    /// a deck of covers doesn't pay for a blurred, offscreen-rendered shadow
    /// on every card.
    var showsShadow: Bool = true

    private var cornerRadius: CGFloat {
        settings.roundedArtwork ? Theme.Radius.lg : 0
    }

    /// Off-main-decoded image for the current cache key. Bridges the gap
    /// between a memory-cache miss and the async decode finishing; once the
    /// decode lands, the memory cache is warm and the fast path takes over.
    /// Tagged with the key it was decoded for so a cell reused for different
    /// artwork never shows the previous image.
    @State private var decoded: DecodedImage? = nil
    private struct DecodedImage {
        let key: String
        let image: NSImage
    }

    private var cacheID: String? {
        guard let data, !data.isEmpty else { return nil }
        return id ?? Self.fallbackID(for: data)
    }

    /// Identity for the async decode task — changes whenever the artwork
    /// source or target size changes.
    private var decodeKey: String? {
        cacheID.map { "\($0)#\(decodeSize)" }
    }

    /// Thumbnail size to decode; the image is then drawn at `size`.
    private var decodeSize: CGFloat { ArtworkImageCache.decodePointSize(for: size) }

    private var resolvedImage: NSImage? {
        guard let data, !data.isEmpty, let cacheID else { return nil }
        if fullResolution {
            // Deliberate synchronous full-res decode: only used by the
            // tap-to-zoom overlay, a single view shown on explicit tap.
            return NSImage(data: data)
        }
        // Memory-only lookup in the body — never disk I/O or decode, which
        // used to run synchronously here on every cold cell mid-scroll.
        if let hit = ArtworkImageCache.shared.cachedThumbnail(
            id: cacheID, pointSize: decodeSize, scale: displayScale
        ) {
            return hit
        }
        if let decoded, decoded.key == decodeKey { return decoded.image }
        return nil
    }

    var body: some View {
        Group {
            if let nsImage = resolvedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                placeholder
            }
        }
        .artworkShadow(size: size, enabled: showsShadow)
        .task(id: decodeKey) {
            guard !fullResolution, let cacheID, let key = decodeKey,
                  let data, !data.isEmpty else { return }
            guard decoded?.key != key else { return }
            guard ArtworkImageCache.shared.cachedThumbnail(
                id: cacheID, pointSize: decodeSize, scale: displayScale
            ) == nil else { return }
            let box = await ArtworkImageCache.shared.thumbnailAsync(
                for: data, id: cacheID, pointSize: decodeSize, scale: displayScale
            )
            guard let image = box.image else { return }
            decoded = DecodedImage(key: key, image: image)
        }
    }

    private static func fallbackID(for data: Data) -> String {
        ArtworkImageCache.contentID(for: data)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.surfaceElevated)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3, weight: .ultraLight))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
            }
    }
}
