import SwiftUI
import AppKit

/// Everything below the artist banner. Albums are "eras": large covers with
/// their year set huge behind them. Clicking one opens it in a spotlight panel
/// (blurred-cover backdrop, details, full tracklist) and tints the section in
/// that album's color. Singles & EPs and Appears On follow as grids.
struct ArtistDiscographyView: View {
    let summary: ArtistSummary
    /// Width of the scroll view, so the covers can size from it.
    let width: CGFloat
    let viewportHeight: CGFloat
    /// Named coordinate space of the enclosing scroll view, for the
    /// scroll-into-view reveals.
    let scrollSpace: String
    /// Light mode's banner tint, carried across the seam so the hero's
    /// bottom flows into the discography.
    let bannerWash: Color?

    @Environment(PlayerState.self)       private var player
    @Environment(ListeningStore.self)    private var listening
    @Environment(Settings.self)          private var settings
    @Environment(NavigationRouter.self)  private var router
    @Environment(\.colorScheme)          private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedAlbumID: String?
    @State private var hoveredAlbumID: String?
    /// Dominant hue per album id, sampled once per album set.
    @State private var albumHues: [String: HomePalette.Swatch] = [:]
    @State private var revealedSections: Set<String> = []

    private static let gutter: CGFloat = Theme.Spacing.xxl
    private static let eraSpacing: CGFloat = 40
    /// Tracks shown in the spotlight before "All N tracks" takes over.
    private static let spotlightTrackLimit = 12
    /// The selection slide: eased at both ends, so the cover, year and record
    /// visibly travel instead of snapping most of the way in the first frames.
    static let selectionMotion = Animation.smooth(duration: 0.7)

    private var isLight: Bool { colorScheme == .light }

    /// Newest first, undated albums last.
    private var eras: [Album] {
        summary.albums.sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
    }

    private var selectedAlbum: Album? {
        eras.first { $0.id == selectedAlbumID } ?? eras.first
    }

    var body: some View {
        let inner = max(width - Self.gutter * 2, 320)
        return VStack(alignment: .leading, spacing: 72) {
            if !eras.isEmpty {
                albumsSection(width: inner)
            }
            if !summary.singles.isEmpty {
                gridSection("Singles & EPs", albums: summary.singles, width: inner, columns: inner > 900 ? 5 : 4)
            }
            if !summary.appearsOn.isEmpty {
                appearsOnSection(width: inner)
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, 120)
        .frame(width: width, alignment: .leading)
        .background(alignment: .top) { wash }
        .task(id: eras.map(\.id)) { await sampleHues() }
    }

    // MARK: - Wash

    /// The section takes the color of the album being hovered, or else the
    /// selected one, the way the banner colors the page above.
    private var wash: some View {
        let id = hoveredAlbumID ?? selectedAlbum?.id
        let color = id.flatMap { albumHues[$0] }.map(washColor(for:)) ?? .clear
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(color)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black.opacity(0.6), location: 0.45),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.8), value: id)
            if isLight, let bannerWash {
                LinearGradient(colors: [bannerWash, bannerWash.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
        }
        .frame(height: 1200)
        .allowsHitTesting(false)
    }

    private func washColor(for swatch: HomePalette.Swatch) -> Color {
        isLight
            ? Color(nsColor: NSColor(hue: swatch.hue, saturation: 0.14, brightness: 0.94, alpha: 1))
            : Color(nsColor: NSColor(hue: swatch.hue, saturation: min(max(swatch.saturation, 0.6), 0.8), brightness: 0.3, alpha: 1))
    }

    /// Samples each album's dominant hue off the main thread.
    private func sampleHues() async {
        let sources = eras.map { (id: $0.id, artwork: $0.artwork) }
        albumHues = await Task.detached(priority: .utility) {
            var hues: [String: HomePalette.Swatch] = [:]
            for source in sources {
                if let data = source.artwork, let swatch = HomePalette.extract(from: data)?.swatches.first {
                    hues[source.id] = swatch
                }
            }
            return hues
        }.value
    }

    // MARK: - Albums: eras + spotlight

    private func albumsSection(width: CGFloat) -> some View {
        let scrolls = eras.count > 3
        // Three across fills the row; with more, a little of the next cover
        // peeks in to show the row scrolls.
        let columns: CGFloat = scrolls ? 3.3 : 3
        let cover = min(floor((width - Self.eraSpacing * (columns - 1)) / columns), 440)
        let revealed = isRevealed("Albums")

        return VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Albums")
                Spacer()
                Text(albumsSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .sectionReveal(revealed, delay: 0, calm: reduceMotion)

            Group {
                if scrolls {
                    ScrollView(.horizontal) {
                        eraRow(cover: cover, revealed: revealed)
                            .padding(.top, 8)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -Self.gutter)
                    .contentMargins(.horizontal, Self.gutter, for: .scrollContent)
                } else {
                    eraRow(cover: cover, revealed: revealed)
                        .padding(.top, 8)
                }
            }

            if let album = selectedAlbum {
                AlbumSpotlight(
                    album: album,
                    width: width,
                    trackLimit: Self.spotlightTrackLimit,
                    currentTrackID: player.currentTrack?.id,
                    play: { startIndex, shuffle in play(album, from: startIndex, shuffle: shuffle) },
                    open: { router.collectionPath.append(album.id) }
                )
                .id(album.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 12)),
                    removal: .opacity
                ))
                .sectionReveal(revealed, delay: 0.3, calm: reduceMotion)
            }
        }
        .animation(Self.selectionMotion, value: selectedAlbum?.id)
        .revealWhenVisible(in: scrollSpace, viewportHeight: viewportHeight) { revealedSections.insert("Albums") }
    }

    private func eraRow(cover: CGFloat, revealed: Bool) -> some View {
        HStack(alignment: .top, spacing: Self.eraSpacing) {
            ForEach(Array(eras.enumerated()), id: \.element.id) { index, album in
                EraCover(
                    album: album,
                    size: cover,
                    isSelected: album.id == selectedAlbum?.id,
                    isHovered: album.id == hoveredAlbumID,
                    isPlaying: isPlaying(album),
                    calm: reduceMotion
                ) {
                    withAnimation(Self.selectionMotion) { selectedAlbumID = album.id }
                }
                .onHover { inside in
                    if inside { hoveredAlbumID = album.id }
                    else if hoveredAlbumID == album.id { hoveredAlbumID = nil }
                }
                .sectionReveal(revealed, delay: 0.08 + min(Double(index) * 0.07, 0.42), calm: reduceMotion)
            }
        }
    }

    /// True while one of the album's tracks is the one playing, so its
    /// record can spin.
    private func isPlaying(_ album: Album) -> Bool {
        guard player.isPlaying, let current = player.currentTrack?.id else { return false }
        return album.tracks.contains { $0.id == current }
    }

    private var albumsSummary: String {
        let years = eras.compactMap(\.year)
        let tracks = eras.reduce(0) { $0 + $1.trackCount }
        var parts: [String] = []
        if let lo = years.min(), let hi = years.max() {
            parts.append(lo == hi ? "\(lo)" : "\(lo) – \(hi)")
        }
        parts.append("\(tracks) track\(tracks == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Singles & EPs

    private func gridSection(_ title: String, albums: [Album], width: CGFloat, columns: Int) -> some View {
        let revealed = isRevealed(title)
        let spacing = Theme.Spacing.xl
        let cell = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return VStack(alignment: .leading, spacing: 20) {
            sectionTitle(title)
                .sectionReveal(revealed, delay: 0, calm: reduceMotion)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                spacing: 28
            ) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    Button { router.collectionPath.append(album.id) } label: {
                        AlbumCardView(album: album, artworkPointSize: cell)
                    }
                    .buttonStyle(.plain)
                    .sectionReveal(revealed, delay: 0.08 + min(Double(index) * 0.06, 0.42), calm: reduceMotion)
                }
            }
        }
        .revealWhenVisible(in: scrollSpace, viewportHeight: viewportHeight) { revealedSections.insert(title) }
    }

    // MARK: - Appears On

    private func appearsOnSection(width: CGFloat) -> some View {
        let title = "Appears On"
        let revealed = isRevealed(title)
        return VStack(alignment: .leading, spacing: 20) {
            sectionTitle(title)
                .sectionReveal(revealed, delay: 0, calm: reduceMotion)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.lg), count: width > 700 ? 2 : 1),
                spacing: Theme.Spacing.lg
            ) {
                ForEach(Array(summary.appearsOn.enumerated()), id: \.element.id) { index, album in
                    AppearanceCard(album: album) { router.collectionPath.append(album.id) }
                        .sectionReveal(revealed, delay: 0.08 + min(Double(index) * 0.06, 0.42), calm: reduceMotion)
                }
            }
        }
        .revealWhenVisible(in: scrollSpace, viewportHeight: viewportHeight) { revealedSections.insert(title) }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .heavy))
            .tracking(-0.5)
            .foregroundStyle(Theme.textPrimary)
    }

    private func isRevealed(_ title: String) -> Bool {
        revealedSections.contains(title) || !settings.fadeAnimationsEnabled
    }

    private func play(_ album: Album, from startIndex: Int?, shuffle: Bool) {
        guard !album.tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let index = startIndex ?? (shuffle ? Int.random(in: 0..<album.tracks.count) : 0)
        player.startFreshQueue(album.tracks, startAt: index, source: album.name)
        player.engine.play()
        listening.recordAlbumPlay(album)
    }
}

// MARK: - Era cover

/// One album in the eras row: the year set huge and faint behind the top of
/// the cover, a vinyl record tucked in the sleeve that slides further out
/// when the album is selected, then the title with a short bar under it.
///
/// Layers, back to front: record, year, cover. The record peeks out the top
/// of the sleeve into the year's band.
private struct EraCover: View {
    let album: Album
    let size: CGFloat
    let isSelected: Bool
    let isHovered: Bool
    let isPlaying: Bool
    let calm: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var yearSize: CGFloat { (size * 0.35).rounded() }
    /// Height of the band above the cover the year occupies; the cover's
    /// top edge cuts across the bottom of the digits.
    private var yearBand: CGFloat { (yearSize * 0.93).rounded() }
    private var recordDiameter: CGFloat { (size * 0.92).rounded() }
    /// How far the record shows above the sleeve.
    private var recordPeek: CGFloat {
        size * (isSelected ? 0.27 : (isHovered ? 0.12 : 0.07))
    }
    private var coverLift: CGFloat {
        guard !calm else { return 0 }
        return isSelected ? -12 : (isHovered ? -5 : 0)
    }
    private var recordOrigin: CGPoint {
        CGPoint(x: size * 0.06, y: yearBand - recordPeek + coverLift)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    VinylRecord(
                        artwork: album.artwork,
                        albumID: album.id,
                        diameter: recordDiameter,
                        isSpinning: isPlaying && !calm
                    )
                    .offset(x: recordOrigin.x, y: recordOrigin.y)

                    yearText(Theme.textPrimary.opacity(isSelected ? 0.62 : (isHovered ? 0.36 : 0.2)))

                    // Dark digits vanish against the black record in light
                    // mode, so the part of the year over the record is
                    // redrawn light.
                    if colorScheme == .light {
                        yearText(.white.opacity(isSelected ? 0.8 : 0.45))
                            .frame(width: size, height: yearBand + size, alignment: .topLeading)
                            .mask(alignment: .topLeading) {
                                Circle()
                                    .frame(width: recordDiameter, height: recordDiameter)
                                    .offset(x: recordOrigin.x, y: recordOrigin.y)
                            }
                    }

                    ArtworkView(data: album.artwork, size: size, id: "album:\(album.id)")
                        .saturation(isSelected || isHovered ? 1 : 0.75)
                        .brightness(isSelected || isHovered ? 0 : -0.08)
                        .padding(.top, yearBand)
                        .offset(y: coverLift)
                }
                .frame(width: size, height: yearBand + size, alignment: .topLeading)

                Text(album.name)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 18)

                Capsule()
                    .fill(Theme.textPrimary)
                    .frame(width: isSelected ? 48 : 0, height: 3)
                    .padding(.top, 12)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(album.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(calm ? .easeOut(duration: 0.25) : ArtistDiscographyView.selectionMotion, value: isSelected)
        .animation(.smooth(duration: 0.4), value: isHovered)
    }

    private func yearText(_ color: Color) -> some View {
        Text(album.year.map(String.init) ?? " ")
            .font(.system(size: yearSize, weight: .heavy))
            .tracking(-yearSize * 0.05)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, -yearSize * 0.045)
            .offset(y: calm ? 0 : (isSelected ? -16 : (isHovered ? -4 : 0)))
    }
}

// MARK: - Spotlight

/// The selected album, opened up: a blurred-cover backdrop like a small
/// banner, its details and controls, and the tracklist.
private struct AlbumSpotlight: View {
    let album: Album
    let width: CGFloat
    let trackLimit: Int
    let currentTrackID: UUID?
    let play: (_ startIndex: Int?, _ shuffle: Bool) -> Void
    let open: () -> Void

    private var tracks: [Track] { Array(album.tracks.prefix(trackLimit)) }

    @State private var backdropImage: NSImage?

    var body: some View {
        let infoWidth = max(260, (width - 80 - 56) * 0.41)

        HStack(alignment: .top, spacing: 56) {
            details
                .frame(width: infoWidth, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
            tracklist
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        .background { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .task(id: album.id) {
            backdropImage = BlurredArtworkCache.shared.cached(id: backdropID)
            if backdropImage == nil {
                backdropImage = await BlurredArtworkCache.shared.image(for: album.artwork, id: backdropID).image
            }
        }
    }

    /// Includes the artwork size so an edited cover gets a fresh backdrop.
    private var backdropID: String { "spotlight:\(album.id):\(album.artwork?.count ?? 0)" }

    private var backdrop: some View {
        ZStack {
            Color.black
            // Blurred once, off the main thread, at a tiny size; drawn here
            // scaled up with no live blur.
            Color.clear
                .overlay {
                    if let image = backdropImage ?? BlurredArtworkCache.shared.cached(id: backdropID) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(1.25)
                            .saturation(1.4)
                            .brightness(-0.22)
                    }
                }
                .clipped()
            LinearGradient(
                colors: [.black.opacity(0.1), .black.opacity(0.5)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kindLine)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
            Text(album.name)
                .font(.system(size: 56, weight: .heavy))
                .tracking(-2)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.top, 10)
            Text(FormatUtils.playlistSummary(trackCount: album.trackCount, duration: album.totalDuration))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.top, 14)
            if let quality = qualityLine {
                Text(quality.text)
                    .font(.system(size: 14))
                    .foregroundStyle(quality.color)
                    .padding(.top, 4)
            }

            Spacer(minLength: 28)

            HStack(spacing: 10) {
                Button { play(nil, false) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(SpotlightPillStyle(isPrimary: true))
                Button { play(nil, true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(SpotlightPillStyle(isPrimary: false))
                Button(action: open) {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .buttonStyle(SpotlightPillStyle(isPrimary: false))
                .help("Open \(album.name)")
            }
        }
    }

    private var tracklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
                alignment: .leading,
                spacing: 2
            ) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    SpotlightTrackRow(
                        number: track.trackNumber ?? index + 1,
                        title: track.title,
                        duration: FormatUtils.formatDuration(track.duration),
                        isCurrent: track.id == currentTrackID
                    ) {
                        play(index, false)
                    }
                }
            }
            if album.trackCount > tracks.count {
                Button("All \(album.trackCount) tracks", action: open)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, -10)
        .padding(.vertical, -6)
    }

    private var kindLine: String {
        var parts = ["Album"]
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private var qualityLine: (text: String, color: Color)? { album.qualitySummary }
}

private struct SpotlightTrackRow: View {
    let number: Int
    let title: String
    let duration: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10))
                    } else if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                    } else {
                        Text("\(number)")
                    }
                }
                .frame(width: 22, alignment: .leading)
                .foregroundStyle(.white.opacity(isCurrent || isHovering ? 1 : 0.62))

                Text(title)
                    .foregroundStyle(.white)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(duration)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .font(.system(size: 13).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(isHovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Play \(title)")
    }
}

private struct SpotlightPillStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isPrimary ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Capsule().fill(isPrimary ? Color.white : Color.white.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Appears On card

private struct AppearanceCard: View {
    let album: Album
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                ArtworkView(data: album.artwork, size: 96, id: "album:\(album.id)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovering ? Theme.surfaceElevated : Theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let artist = ArtistResolver.displayString(album.albumArtist ?? album.artist) { parts.append(artist) }
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reveal helpers

extension View {
    /// Content fading up as its section scrolls into view.
    func sectionReveal(_ revealed: Bool, delay: Double, calm: Bool) -> some View {
        self
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || calm ? 0 : 28)
            .animation(
                calm ? .easeOut(duration: 0.3)
                     : .timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(delay),
                value: revealed
            )
    }

    /// Calls `reveal` once the view's top is within the viewport.
    func revealWhenVisible(in space: String, viewportHeight: CGFloat, reveal: @escaping () -> Void) -> some View {
        onGeometryChange(for: Bool.self) { geometry in
            geometry.frame(in: .named(space)).minY < viewportHeight - 90
        } action: { inView in
            if inView { reveal() }
        }
    }
}
