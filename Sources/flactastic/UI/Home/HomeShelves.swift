import SwiftUI

// MARK: - Header

/// A Home section's heading: title, a short line on what it is, and an
/// action on the right ("Show all", "Play all").
struct HomeSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: UIStyle.shared.sectionTitleSize, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let subtitle, UIStyle.shared.homeSubtitles {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension HomeSectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Shelf

/// One row of tiles that scrolls sideways. When there are more than fit,
/// "Show all" opens the same items as a grid right here, rather than on
/// another page; "Show less" folds it back.
struct HomeShelf<Item: Identifiable, Tile: View>: View {
    let title: String
    var subtitle: String? = nil
    let items: [Item]
    var tileWidth: CGFloat = HomeTile.size
    @ViewBuilder let tile: (Item) -> Tile

    @State private var expanded = false
    @State private var width: CGFloat = 0

    private var fits: Int { max(1, Int((width + HomeTile.spacing) / (tileWidth + HomeTile.spacing))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: title, subtitle: subtitle) {
                if items.count > fits {
                    Button(expanded ? "Show less" : "Show all") {
                        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)) { expanded.toggle() }
                    }
                    .buttonStyle(QuietTextButtonStyle())
                }
            }
            Group {
                if expanded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth + 40), spacing: HomeTile.spacing, alignment: .top)],
                              alignment: .leading, spacing: 22) {
                        ForEach(items) { tile($0) }
                    }
                    .padding(.vertical, 6)
                    .transition(.opacity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: HomeTile.spacing) {
                            ForEach(items) { tile($0) }
                        }
                        // Room for the hover lift and its shadow.
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }
                    .padding(.horizontal, -2)
                    .transition(.opacity)
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        }
    }
}

/// Home's cover size and the gap between covers, as UI for nerds sets them.
@MainActor
enum HomeTile {
    static var size: CGFloat { UIStyle.shared.homeCoverSize }
    static var spacing: CGFloat { UIStyle.shared.homeDensity }
}

// MARK: - Play button

/// The round play button that rises onto a cover on hover.
struct HomePlayButton: View {
    var diameter: CGFloat = 40
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: diameter * 0.36, weight: .bold))
                .foregroundStyle(Theme.background)
                .offset(x: diameter * 0.03)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Theme.accent))
                .scaleEffect(isHovering ? 1.06 : 1)
                .shadow(color: .black.opacity(0.4), radius: 9, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help("Play")
        .accessibilityLabel("Play")
    }
}

// MARK: - Album tile

/// A cover that lifts on hover, title and a caption beneath. Clicking opens
/// it; the play button plays it without leaving Home.
struct HomeAlbumTile: View {
    let artwork: Data?
    let artworkID: String?
    let title: String
    let caption: Text
    var size: CGFloat = HomeTile.size
    var badge: AudioQuality? = nil
    let onOpen: () -> Void
    var onPlay: (() -> Void)? = nil
    var menu: () -> [FLContextMenuItem] = { [] }

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkView(data: artwork, size: size, id: artworkID, showsShadow: false)
                    .overlay(alignment: .topLeading) {
                        if let badge, UIStyle.shared.homeBadges {
                            Text(badge.label.uppercased())
                                .font(.system(size: 10.5, weight: .heavy))
                                .foregroundStyle(badge.color)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
                    .shadow(color: .black.opacity(isHovering ? 0.45 : 0.28), radius: isHovering ? 14 : 6, y: isHovering ? 10 : 4)
                    .offset(y: isHovering ? -3 : 0)
                if UIStyle.shared.homeCaptions {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        caption
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if let onPlay {
                HomePlayButton(action: onPlay)
                    .padding(10)
                    .frame(width: size, height: size, alignment: .bottomTrailing)
                    .offset(y: isHovering ? -3 : 3)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
        }
        .onHover { hovering in
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3)) { isHovering = hovering }
        }
        .flContextMenu { menu() }
    }
}

// MARK: - Mix row

/// The mixes, larger than an album shelf's covers: there are only ever a
/// few, so the cards grow to fill the row (up to `maxSize`) rather than
/// leave it half empty. Past `minSize` they stop shrinking and the row
/// scrolls instead.
struct HomeMixRow<Tile: View>: View {
    let title: String
    var subtitle: String? = nil
    let mixes: [HomeFeed.Mix]
    var minSize: CGFloat = 210
    var maxSize: CGFloat = UIStyle.shared.mixTileSize
    @ViewBuilder let tile: (HomeFeed.Mix, CGFloat) -> Tile

    @State private var width: CGFloat = 0

    var body: some View {
        let spacing = HomeTile.spacing
        let count = CGFloat(max(mixes.count, 1))
        let fill = floor((width - spacing * (count - 1)) / count)
        let size = min(maxSize, max(min(minSize, maxSize), fill))
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(mixes) { tile($0, size) }
                }
                // Room for the hover lift and its shadow.
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, -2)
            .opacity(width > 0 ? 1 : 0)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        }
    }
}

// MARK: - Mix tile

/// A mix's cover: its lead artist's picture in black and white with the
/// mix's colour laid over it, the mix's name across the bottom. Clicking
/// plays it.
struct HomeMixTile: View {
    let mix: HomeFeed.Mix
    let image: Data?
    var size: CGFloat = HomeTile.size
    let onPlay: () -> Void
    var menu: () -> [FLContextMenuItem] = { [] }

    @State private var isHovering = false

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 10) {
                MixCoverArt(mix: mix, size: size,
                            // Grows with the card, so a wide card doesn't look under-titled.
                            nameSize: 19 * min(1.4, size / HomeTile.size)) {
                    if let image {
                        ArtworkView(data: image, size: size, showsShadow: false, alwaysSquare: true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.accent))
                        .shadow(color: .black.opacity(0.4), radius: 9, y: 6)
                        .padding(10)
                        .opacity(isHovering ? 1 : 0)
                        .offset(y: isHovering ? 0 : 6)
                }
                .shadow(color: .black.opacity(isHovering ? 0.45 : 0.28), radius: isHovering ? 14 : 6, y: isHovering ? 10 : 4)
                .offset(y: isHovering ? -3 : 0)
                Text(mix.artists.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3)) { isHovering = hovering }
        }
        .help("Play \(mix.name) · \(mix.tracks.count) tracks")
        .flContextMenu { menu() }
    }
}

/// A mix's cover art, shared by its Home card and the cover saved with it:
/// the lead artist's photo in black and white with the mix's colour laid
/// over it (shadows take the hue, highlights keep a little of the photo),
/// and the name across the bottom.
struct MixCoverArt<Photo: View>: View {
    let mix: HomeFeed.Mix
    let size: CGFloat
    let nameSize: CGFloat
    @ViewBuilder var photo: () -> Photo

    var body: some View {
        let hue = mix.color
        let inset = size * 0.082
        ZStack(alignment: .bottomLeading) {
            hue
            photo()
                .frame(width: size, height: size)
                .clipped()
                .grayscale(1)
                .contrast(1.12)
                .colorMultiply(hue)
                .opacity(UIStyle.shared.mixPhotoStrength)
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .center)
                .blendMode(.softLight)
            LinearGradient(colors: [.clear, hue.mix(with: .black, by: 0.45).opacity(0.95)],
                           startPoint: .center, endPoint: .bottom)
            Text(mix.name)
                .font(.system(size: nameSize, weight: .heavy))
                .tracking(-nameSize * 0.02)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, inset)
                .padding(.bottom, inset * 0.9)
        }
        .frame(width: size, height: size)
    }
}

extension HomeFeed.Mix {
    var color: Color {
        let c = HomeFeed.mixHues[hue % HomeFeed.mixHues.count]
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// The cover rendered once, as a 1024 × 1024 JPEG, to save with the
    /// playlist: the same art as the card, with the name in proportion.
    @MainActor
    func coverJPEG(photo: Data?, side: CGFloat = 1024) -> Data? {
        let image = photo.flatMap(NSImage.init(data:))
        let art = MixCoverArt(mix: self, size: side, nameSize: side * 0.095) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        let renderer = ImageRenderer(content: art)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

private extension Color {
    func mix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * amount,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount)
    }
}

// MARK: - On repeat row

struct HomeRepeatRow: View {
    let rank: Int
    let track: Track
    let plays: Int
    let onPlay: () -> Void
    var menu: () -> [FLContextMenuItem] = { [] }

    @State private var isHovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 22, alignment: .trailing)
                ArtworkView(data: track.artwork, size: 44, id: "track:\(track.id)", showsShadow: false)
                    .overlay {
                        if isHovering {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(ArtistResolver.displayString(track.artist) ?? track.artist ?? "Unknown Artist")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if UIStyle.shared.repeatShowPlays {
                    (Text("\(plays)").foregroundColor(Theme.textSecondary).fontWeight(.semibold) + Text(" plays"))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.textPrimary.opacity(isHovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .flContextMenu { menu() }
    }
}

// MARK: - Today's pick

/// The day's lead recommendation, large: its cover filling the card, why it
/// was picked, and a play button.
struct HomeTodayFeature: View {
    let album: Album
    let why: String
    let width: CGFloat
    let height: CGFloat
    let onOpen: () -> Void
    let onPlay: () -> Void
    var menu: () -> [FLContextMenuItem] = { [] }

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(data: album.artwork, size: max(width, height), id: "album:\(album.id)", showsShadow: false, alwaysSquare: true)
                    .frame(width: width, height: height)
                    .clipped()
                    .scaleEffect(isHovering ? 1.03 : 1)
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Today's pick")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.66))
                    Text(album.name)
                        .font(.system(size: 28, weight: .heavy))
                        .tracking(-0.8)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.top, 6)
                    Text([ArtistResolver.displayString(album.artist), album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(.top, 6)
                    Text(why)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: width - 100, alignment: .leading)
                        .padding(.top, 12)
                }
                .padding(20)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            HomePlayButton(diameter: 48, action: onPlay).padding(20)
        }
        .onHover { hovering in
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { isHovering = hovering }
        }
        .flContextMenu { menu() }
    }
}

// MARK: - Today grid

/// Today's lead pick beside two rows of the rotation. The rows hold as many
/// covers as the width fits (up to six across), so there's never a gap; the
/// lead card is exactly as tall as the two rows.
struct HomeTodayGrid<Feature: View, Tile: View>: View {
    let albums: [Album]
    @ViewBuilder let feature: (CGFloat, CGFloat) -> Feature
    @ViewBuilder let tile: (Album, CGFloat) -> Tile

    @State private var width: CGFloat = 0

    var body: some View {
        let spacing = HomeTile.spacing
        let style = UIStyle.shared
        let rows = max(1, min(2, style.todayRows))
        let featureWidth = min(400, max(300, width * 0.3))
        let rest = max(0, width - featureWidth - spacing)
        // Columns as narrow as a little under Home's cover size allows.
        let columns = min(6, max(2, Int((rest + spacing) / (HomeTile.size * 0.88 + spacing))))
        let tileSize = floor((rest - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        // Cover, gap, two caption lines; the rows and the gaps between them.
        let captions: CGFloat = style.homeCaptions ? 10 + 34 : 0
        let rowHeight = tileSize + captions
        let height = rowHeight * CGFloat(rows) + 22 * CGFloat(rows - 1) - (style.homeCaptions ? 34 : 0)

        Group {
            if width > 0, tileSize > 60 {
                HStack(alignment: .top, spacing: spacing) {
                    feature(featureWidth, height)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileSize), spacing: spacing, alignment: .top), count: columns),
                              alignment: .leading, spacing: 22) {
                        ForEach(albums.prefix(columns * rows)) { tile($0, tileSize) }
                    }
                }
            } else {
                Color.clear.frame(height: 320)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        }
    }
}
