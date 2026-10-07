import SwiftUI

/// An album, in the artist page's language: a hero on a blurred wash of the
/// cover, then the tracklist and more from the same artist. Arrives with the
/// artist page's entrance: the page zooms in from blurred, then the cover,
/// title, details and buttons follow in sequence.
struct AlbumDetailView: View {
    let albumID: String

    @Environment(\.topBarInset) private var topBarInset
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(NavigationRouter.self) private var router
    @Environment(ListeningStore.self) private var listening
    @Environment(Settings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Track IDs we've observed belonging to this album. Used as a fallback
    /// for resolving the album after a metadata edit renames the album/artist
    /// (which changes `Album.id` since that id is derived from artist+name).
    @State private var knownTrackIDs: Set<UUID> = []

    private var album: Album? {
        if let exact = library.albumsByID[albumID] {
            return exact
        }
        guard !knownTrackIDs.isEmpty else { return nil }
        return library.albums.first { candidate in
            candidate.tracks.contains { knownTrackIDs.contains($0.id) }
        }
    }

    @State private var isEditingAlbum = false
    @State private var editingTrack: Track? = nil
    @State private var removalRequest: LibraryRemovalRequest? = nil
    @State private var hasEntered = false
    /// The cover, blurred once off the main thread for the backdrop.
    @State private var backdrop: NSImage?
    /// Width of one "More by" cover, so it decodes at the size it's drawn.
    @State private var moreCellWidth: CGFloat = 180
    /// "More by": the album's artists and their other albums, worked out
    /// once per album and library change rather than on every redraw.
    @State private var moreBy = MoreBy()

    private struct MoreBy {
        var names: [String] = []
        var albums: [Album] = []
    }

    private static let heroHeight: CGFloat = 560

    private var isLight: Bool { colorScheme == .light }
    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }
    private var ink: Color { isLight ? Theme.textPrimary : .white }
    private var inkSecondary: Color { isLight ? Color(white: 0.28) : .white.opacity(0.85) }

    var body: some View {
        if let album {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(album)
                    trackList(album)
                        .padding(.horizontal, collectionGutter - 16)
                        .padding(.top, 8)
                        .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.8))
                    moreByArtist(album)
                        .padding(.horizontal, collectionGutter)
                        .padding(.top, 56)
                        .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.9))
                }
                .padding(.bottom, 110)
            }
            .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
            .blur(radius: hasEntered || calmMotion ? 0 : 28)
            .opacity(hasEntered ? 1 : 0)
            .background(Theme.background)
            .onAppear {
                knownTrackIDs = Set(album.tracks.map(\.id))
                withAnimation(calmMotion
                              ? .easeOut(duration: 0.3)
                              : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1)) {
                    hasEntered = true
                }
            }
            .onChange(of: album.tracks.map(\.id)) { _, ids in
                knownTrackIDs = Set(ids)
            }
            .task(id: "\(album.id)|\(library.tracksRevision)") {
                moreBy = computeMoreBy(album)
            }
            .task(id: backdropID(album)) {
                backdrop = BlurredArtworkCache.shared.cached(id: backdropID(album))
                if backdrop == nil {
                    backdrop = await BlurredArtworkCache.shared.image(for: album.artwork, id: backdropID(album)).image
                }
            }
            .sheet(isPresented: $isEditingAlbum) {
                AlbumMetadataEditorView(album: album)
                    .environment(library)
            }
            .removeFromLibraryConfirmation($removalRequest, library: library)
            .sheet(item: $editingTrack) { track in
                TrackMetadataEditorView(track: track)
                    .environment(library)
            }
        } else {
            Text("Album not found")
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
    }

    private var arrive: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.7) }

    /// Shared with the artist spotlight, so an album's backdrop is blurred once.
    private func backdropID(_ album: Album) -> String {
        "spotlight:\(album.id):\(album.artwork?.count ?? 0)"
    }

    // MARK: - Hero

    private func hero(_ album: Album) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdropLayer
                .scaleEffect(hasEntered || calmMotion ? 1 : 1.14)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.9), value: hasEntered)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(isLight ? 0.12 : 0.35), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: Theme.background.opacity(0.25), location: 0.6),
                    .init(color: Theme.background, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 40) {
                ArtworkView(data: album.artwork, size: 320, id: "album:\(album.id)")
                    .shadow(color: .black.opacity(isLight ? 0.25 : 0.6), radius: 30, y: 24)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            router.artworkZoomData = album.artwork
                        }
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .help("View artwork")
                    .flContextMenu {
                        menus.album(
                            album,
                            edit: { isEditingAlbum = true },
                            remove: { removalRequest = LibraryRemovalRequest(title: album.name, tracks: album.tracks) }
                        )
                    }
                    .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
                    .opacity(hasEntered ? 1 : 0)
                    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(calmMotion ? 0 : 0.22), value: hasEntered)

                heroDetails(album)
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, collectionGutter)
            .padding(.bottom, 44)
        }
        // Runs up under the top bar, so the bar floats over the backdrop.
        .frame(height: Self.heroHeight + topBarInset)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            HeroBackButton { router.goBackInCollection() }
                .padding(.leading, collectionGutter)
                .padding(.top, Theme.Spacing.xl + topBarInset)
                .opacity(hasEntered ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(calmMotion ? 0 : 0.15), value: hasEntered)
        }
    }

    /// The pre-blurred cover, drawn scaled up with no live blur.
    private var backdropLayer: some View {
        Color.clear
            .overlay {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.2)
                        .saturation(1.4)
                        .brightness(isLight ? 0.18 : -0.2)
                } else {
                    Theme.surface
                }
            }
            .clipped()
            .allowsHitTesting(false)
    }

    private func heroDetails(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title rises out of its own line, clipped like a reveal.
            Text(album.name)
                .font(.system(size: 80, weight: .heavy))
                .tracking(-3)
                .foregroundStyle(ink)
                .lineLimit(2)
                .minimumScaleFactor(0.45)
                .offset(y: hasEntered || calmMotion ? 0 : 160)
                .padding(.bottom, 6)
                .clipped()
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.95).delay(calmMotion ? 0 : 0.32), value: hasEntered)

            HStack(spacing: 0) {
                if album.isCompilation {
                    Text("Compilation")
                        .foregroundStyle(ink)
                } else {
                    ArtistLink(credit: album.albumArtist ?? album.artist, font: .system(size: 16, weight: .semibold), color: ink)
                }
                Text(kindLine(album))
                    .foregroundStyle(inkSecondary)
            }
            .font(.system(size: 16))
            .lineLimit(1)
            .padding(.top, 8)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

            HStack(spacing: 12) {
                Text(FormatUtils.playlistSummary(trackCount: album.trackCount, duration: album.totalDuration))
                    .font(.system(size: 14))
                    .foregroundStyle(inkSecondary)
                if let quality = album.qualitySummary {
                    Text(quality.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(quality.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(quality.color.opacity(isLight ? 0.14 : 0.18)))
                }
            }
            .padding(.top, 10)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

            HStack(spacing: Theme.Spacing.md) {
                Button { playAlbum(album, shuffle: false) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(HeroPillStyle(kind: .primary, ink: ink, isLight: isLight))
                Button { playAlbum(album, shuffle: true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                Button { isEditingAlbum = true } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                .help("Edit album")
                .accessibilityLabel("Edit album")
            }
            .padding(.top, 24)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.62))
        }
    }

    /// " · Album · 2024 · Electronic" after the artist.
    private func kindLine(_ album: Album) -> String {
        var parts = [album.isMixCompilation ? "Mix Compilation" : "Album"]
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre { parts.append(genre) }
        parts.append(contentsOf: album.secondaryGenres)
        return " · " + parts.joined(separator: " · ")
    }

    // MARK: - Track list

    private func trackList(_ album: Album) -> some View {
        // Lazy so a 100-track box set doesn't build every row up front.
        LazyVStack(spacing: 2) {
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                AlbumTrackRow(
                    track: track,
                    number: track.trackNumber ?? index + 1,
                    fallbackArtist: album.albumArtist ?? album.artist,
                    isCurrent: player.currentTrack?.id == track.id,
                    play: { play(album, from: index) }
                )
                .flContextMenu {
                    menus.track(
                        track,
                        viewAlbum: false,
                        edit: { editingTrack = track },
                        remove: { removalRequest = LibraryRemovalRequest(title: track.title, tracks: [track]) }
                    )
                }
            }
        }
    }

    // MARK: - More by

    /// Other albums by the same album artist, newest first.
    /// Other albums by any of this album's artists, each on their own: a
    /// collaboration by three artists also brings in each one's solo work
    /// and their other collaborations. Albums sharing more of the artists
    /// come first, then newest first.
    private func computeMoreBy(_ album: Album) -> MoreBy {
        guard !album.isCompilation else { return MoreBy() }
        let resolver = library.makeArtistResolver()
        let keys = resolver.keys(forCredit: album.albumArtist ?? album.artist)
        guard !keys.isEmpty else { return MoreBy() }
        let keySet = Set(keys)
        var scored: [(album: Album, shared: Int)] = []
        for other in library.albums where other.id != album.id && !other.isCompilation {
            let shared = Set(resolver.keys(forCredit: other.albumArtist ?? other.artist))
                .intersection(keySet).count
            if shared > 0 { scored.append((other, shared)) }
        }
        scored.sort { a, b in
            if a.shared != b.shared { return a.shared > b.shared }
            return (a.album.year ?? 0) > (b.album.year ?? 0)
        }
        return MoreBy(names: keys.map(resolver.displayName(forKey:)), albums: scored.map(\.album))
    }

    /// "ISOxo", "ISOxo and Knock2", "ISOKNOCK, ISOxo and Knock2".
    private static func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    @ViewBuilder
    private func moreByArtist(_ album: Album) -> some View {
        let others = moreBy.albums
        if !others.isEmpty {
            let artist = Self.joinedNames(moreBy.names)
            VStack(alignment: .leading, spacing: 20) {
                Text("More by \(artist)")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Self.moreSpacing), count: Self.moreColumns),
                    alignment: .leading,
                    spacing: 28
                ) {
                    ForEach(others.prefix(Self.moreColumns * 2)) { other in
                        Button { router.collectionPath.append(other.id) } label: {
                            AlbumCardView(album: other, artworkPointSize: moreCellWidth)
                        }
                        .buttonStyle(.plain)
                        .flContextMenu {
                            menus.album(
                                other,
                                open: { router.collectionPath.append(other.id) },
                                remove: { removalRequest = LibraryRemovalRequest(title: other.name, tracks: other.tracks) },
                                showArtists: false
                            )
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    moreCellWidth = (width - Self.moreSpacing * CGFloat(Self.moreColumns - 1)) / CGFloat(Self.moreColumns)
                }
            }
        }
    }

    private static let moreColumns = 6
    private static let moreSpacing: CGFloat = 20

    // MARK: - Actions

    private var menus: LibraryMenus {
        LibraryMenus(player: player, library: library, playlistStore: playlistStore, playlistAdd: playlistAddCoordinator, router: router)
    }

    private func play(_ album: Album, from index: Int) {
        player.startFreshQueue(album.tracks, startAt: index, source: album.name)
        player.engine.play()
        listening.recordAlbumPlay(album)
    }

    private func playAlbum(_ album: Album, shuffle: Bool) {
        guard !album.tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let startIndex = shuffle ? Int.random(in: 0..<album.tracks.count) : 0
        player.startFreshQueue(album.tracks, startAt: startIndex, source: album.name)
        player.engine.play()
        listening.recordAlbumPlay(album)
    }
}

// MARK: - Track row

/// One track: number (a play button on hover), title with every credited
/// artist beneath it, the quality badge and the length.
private struct AlbumTrackRow: View {
    let track: Track
    let number: Int
    /// Shown when the track carries no artist tag of its own.
    let fallbackArtist: String?
    let isCurrent: Bool
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 18) {
            Button(action: play) {
                Group {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    } else if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                ArtistLink(
                    credit: track.artist ?? fallbackArtist,
                    font: .system(size: 13),
                    color: Theme.textSecondary
                )
                .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.md)

            TrackQualityBadge(track: track)

            Text(FormatUtils.formatDuration(track.duration))
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: TrackRow.lengthColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? Theme.surfaceElevated : (isHovering ? Theme.surface : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: play)
    }
}

private extension View {
    /// Fades and lifts into place when `active` flips, after the zoom.
    func arrival(_ active: Bool, calm: Bool, animation: Animation) -> some View {
        self
            .opacity(active ? 1 : 0)
            .offset(y: active || calm ? 0 : 16)
            .animation(calm ? .easeOut(duration: 0.3) : animation, value: active)
    }
}
