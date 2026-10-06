import SwiftUI

struct AlbumCardView: View {
    @Environment(Settings.self) private var settings
    @Environment(\.displayScale) private var displayScale

    let album: Album
    /// Size the cover is drawn at, when a layout makes it larger than the
    /// standard grid cell. Decoding at 180pt and stretching looks soft.
    var artworkPointSize: CGFloat? = nil

    /// Drives the card's rise and the cover's highlight together, so hovering
    /// anywhere on the card — cover or captions — lights the whole thing.
    @State private var isHovering = false

    private let artSize: CGFloat = 180
    private var decodeSize: CGFloat {
        guard let artworkPointSize, artworkPointSize > artSize else { return artSize }
        return ArtworkImageCache.decodePointSize(for: artworkPointSize)
    }
    private var cornerRadius: CGFloat { settings.roundedArtwork ? Theme.Radius.md : 0 }

    private var artworkCacheID: String { "album:\(album.id)" }
    /// Identity of the decoded image: the album plus the size it was decoded at.
    private var decodedKey: String { "\(artworkCacheID)#\(decodeSize)" }

    /// Off-main-decoded image, tagged with the cache id it was decoded for so
    /// a cell whose identity changes never shows the previous album's cover.
    /// See `ArtworkView.decoded` for the pattern.
    @State private var decoded: DecodedImage? = nil
    private struct DecodedImage {
        let key: String
        let image: NSImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { albumArtwork }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .artworkShadow(size: artSize)
                .coverHoverHighlight(isHovering: isHovering, cornerRadius: cornerRadius)
                .padding(.bottom, 7)

            Text(album.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Text(album.isCompilation
                 ? "Compilation"
                 : (ArtistResolver.displayString(album.artist) ?? "Unknown Artist"))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .cardHoverLift(isHovering: isHovering)
        .onHover { isHovering = $0 }
        .task(id: decodedKey) {
            guard resolvedImage == nil, let data = album.artwork else { return }
            let box = await ArtworkImageCache.shared.thumbnailAsync(
                for: data, id: artworkCacheID, pointSize: decodeSize, scale: displayScale
            )
            guard let image = box.image else { return }
            decoded = DecodedImage(key: decodedKey, image: image)
        }
    }

    /// Memory-only lookup in the body — the disk read / decode for cold cells
    /// happens in the `.task` above so scrolling never blocks on it.
    private var resolvedImage: NSImage? {
        if let hit = ArtworkImageCache.shared.cachedThumbnail(
            id: artworkCacheID, pointSize: decodeSize, scale: displayScale
        ) {
            return hit
        }
        if let decoded, decoded.key == decodedKey { return decoded.image }
        return nil
    }

    @ViewBuilder
    private var albumArtwork: some View {
        if let nsImage = resolvedImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Theme.surfaceElevated
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(Theme.textTertiary.opacity(0.5))
                }
        }
    }
}
