import SwiftUI

/// A playlist, in the album page's language: a hero on a blurred wash of
/// its cover, then its tracks, which can be dragged to reorder. Arrives
/// with the same entrance as the artist and album pages: the page zooms in
/// from blurred, then the cover, title, details and buttons follow.
struct PlaylistDetailView: View {
    let playlistID: UUID

    @Environment(\.topBarInset) private var topBarInset
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(NavigationRouter.self) private var router
    @Environment(ListeningStore.self) private var listening
    @Environment(PlaylistAddCoordinator.self) private var playlistAdd
    @Environment(Settings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var selection: Set<UUID> = []
    @State private var showEditor = false
    @State private var draggingEntryID: UUID? = nil
    @State private var dropTargetEntryID: UUID? = nil
    @State private var hasEntered = false
    @State private var editingTrack: Track?
    @State private var removalRequest: LibraryRemovalRequest?
    /// The cover, blurred once off the main thread for the backdrop.
    @State private var backdrop: NSImage?

    private static let heroHeight: CGFloat = 540

    private var isLight: Bool { colorScheme == .light }
    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }
    private var ink: Color { isLight ? Theme.textPrimary : .white }
    private var inkSecondary: Color { isLight ? Color(white: 0.28) : .white.opacity(0.85) }
    private var arrive: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.7) }

    private var playlist: Playlist? {
        playlistStore.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        if let playlist {
            let tracks = playlistStore.resolvedTracks(for: playlist, in: library)
            let cover = playlist.customArtwork ?? tracks.first?.artwork

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(playlist, tracks: tracks, cover: cover)

                    Group {
                        if tracks.isEmpty {
                            emptyState
                        } else {
                            FLTrackListHeader(showDragHandle: true)
                            trackList(playlist)
                        }
                    }
                    .padding(.horizontal, collectionGutter)
                    .padding(.top, 8)
                    .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.8))
                }
                .padding(.bottom, 100)
            }
            .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
            .blur(radius: hasEntered || calmMotion ? 0 : 28)
            .opacity(hasEntered ? 1 : 0)
            .background(Theme.background)
            .onAppear {
                withAnimation(calmMotion
                              ? .easeOut(duration: 0.3)
                              : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1)) {
                    hasEntered = true
                }
            }
            .task(id: backdropID(playlist, cover: cover)) {
                let id = backdropID(playlist, cover: cover)
                backdrop = BlurredArtworkCache.shared.cached(id: id)
                if backdrop == nil {
                    backdrop = await BlurredArtworkCache.shared.image(for: cover, id: id).image
                }
            }
            .sheet(isPresented: $showEditor) {
                PlaylistEditorView(playlistID: playlistID)
            }
            .sheet(item: $editingTrack) { track in
                TrackMetadataEditorView(track: track)
                    .environment(library)
            }
            .removeFromLibraryConfirmation($removalRequest, library: library)
        } else {
            Text("Playlist not found")
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
    }

    /// Shared with the Playlists tab's stage, so a cover is blurred once.
    private func backdropID(_ playlist: Playlist, cover: Data?) -> String {
        if let custom = playlist.customArtwork {
            return "playlist-stage:playlist:\(playlist.id):\(custom.count)"
        }
        return "playlist-stage:\(cover.map(ArtworkImageCache.contentID(for:)) ?? playlist.id.uuidString)"
    }

    // MARK: - Hero

    private func hero(_ playlist: Playlist, tracks: [Track], cover: Data?) -> some View {
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
                ArtworkView(data: cover, size: 300, id: playlist.customArtwork.map { "playlist:\(playlist.id):\($0.count)" })
                    .shadow(color: .black.opacity(isLight ? 0.25 : 0.6), radius: 30, y: 24)
                    .flContextMenu {
                        playbackContextMenuItems(for: tracks, player: player)
                        FLContextMenuItem.divider
                        FLContextMenuItem.button("Edit...", systemImage: "pencil") { showEditor = true }
                    }
                    .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
                    .opacity(hasEntered ? 1 : 0)
                    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(calmMotion ? 0 : 0.22), value: hasEntered)

                heroDetails(playlist, tracks: tracks)
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
            HeroBackButton { router.goBackInPlaylists() }
                .help(router.playlistsBackTitle)
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

    private func heroDetails(_ playlist: Playlist, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title rises out of its own line, clipped like a reveal.
            // Double-click to rename in place.
            Group {
                if isEditingName {
                    TextField("Playlist name", text: $editedName)
                        .textFieldStyle(.plain)
                        .onSubmit { commitRename() }
                        .onExitCommand { isEditingName = false }
                } else {
                    Text(playlist.name)
                        .lineLimit(2)
                        .minimumScaleFactor(0.45)
                        .onTapGesture(count: 2) {
                            editedName = playlist.name
                            isEditingName = true
                        }
                        .help("Double-click to rename")
                }
            }
            .font(.system(size: 80, weight: .heavy))
            .tracking(-3)
            .foregroundStyle(ink)
            .offset(y: hasEntered || calmMotion ? 0 : 160)
            .padding(.bottom, 6)
            .clipped()
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.95).delay(calmMotion ? 0 : 0.32), value: hasEntered)

            if let description = playlist.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 16))
                    .foregroundStyle(inkSecondary)
                    .lineLimit(2)
                    .padding(.top, 8)
                    .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))
            }

            Text("Playlist · " + FormatUtils.playlistSummary(
                trackCount: tracks.count,
                duration: tracks.reduce(0) { $0 + ($1.duration ?? 0) }
            ))
            .font(.system(size: 14))
            .foregroundStyle(inkSecondary)
            .padding(.top, 10)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

            if !tracks.isEmpty {
                QualityMixBar(tracks: tracks, width: 220, ink: inkSecondary)
                    .padding(.top, 10)
                    .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))
            }

            HStack(spacing: Theme.Spacing.md) {
                if !tracks.isEmpty {
                    Button { playAll(tracks, playlist: playlist, shuffle: false) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(HeroPillStyle(kind: .primary, ink: ink, isLight: isLight))
                    Button { playAll(tracks, playlist: playlist, shuffle: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                }
                Button { showEditor = true } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                .help("Edit cover, name and description")
                .accessibilityLabel("Edit playlist")
            }
            .padding(.top, 24)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.62))
        }
    }

    private func playAll(_ tracks: [Track], playlist: Playlist, shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let start = shuffle ? Int.random(in: 0..<tracks.count) : 0
        player.startFreshQueue(tracks, startAt: start, source: playlist.name)
        player.engine.play()
        listening.recordPlaylistPlay(playlist)
    }

    // MARK: - Track List

    @ViewBuilder
    private func trackList(_ playlist: Playlist) -> some View {
        let lookup = buildTrackLookup()

        // SwiftUI's List `.onMove` is unreliable on macOS with `.listStyle(.plain)`,
        // so reordering is implemented with `.draggable` / `.dropDestination`
        // on a LazyVStack instead.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                if let track = resolveEntry(entry, lookup: lookup) {
                    draggablePlaylistRow(
                        entry: entry,
                        track: track,
                        index: index,
                        playlist: playlist
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func draggablePlaylistRow(entry: PlaylistEntry,
                                      track: Track,
                                      index: Int,
                                      playlist: Playlist) -> some View {
        let entryID = entry.id
        let isDropTarget = dropTargetEntryID == entryID && draggingEntryID != entryID
        // `nil` lets `flRowStyle` supply its own hover fill.
        let rowBackground: Color? = player.currentTrack?.id == track.id
            ? Theme.surfaceElevated
            : (selection.contains(entryID) ? Theme.surfaceElevated.opacity(0.6) : nil)

        TrackRow(track: track,
                 isPlaying: player.currentTrack?.id == track.id,
                 displayNumber: index + 1,
                 showDragHandle: true,
                 showAlbumArt: true)
            .flRowStyle(fill: rowBackground)
            .opacity(draggingEntryID == entryID ? 0.4 : 1.0)
            .overlay(alignment: .top) {
                if isDropTarget {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                playFromEntry(entry, in: playlist)
            }
            .flContextMenu { contextMenuItems(for: entry, track: track) }
            .draggable(entryID.uuidString) {
                TrackRow(track: track,
                         isPlaying: false,
                         displayNumber: index + 1,
                         showDragHandle: true,
                         showAlbumArt: true)
                    .frame(width: 360)
                    .background(Theme.surfaceElevated)
                    .cornerRadius(Theme.Radius.sm)
                    .onAppear { draggingEntryID = entryID }
                    .onDisappear {
                        draggingEntryID = nil
                        dropTargetEntryID = nil
                    }
            }
            .dropDestination(for: String.self) { items, _ in
                dropTargetEntryID = nil
                draggingEntryID = nil
                guard let s = items.first, let srcID = UUID(uuidString: s) else {
                    return false
                }
                playlistStore.moveEntry(id: srcID, before: entryID, in: playlistID)
                return true
            } isTargeted: { hovering in
                dropTargetEntryID = hovering ? entryID : (dropTargetEntryID == entryID ? nil : dropTargetEntryID)
            }
    }

    // MARK: - Context Menu

    private func contextMenuItems(for entry: PlaylistEntry, track: Track) -> [FLContextMenuItem] {
        // Right-clicking one of several selected rows acts on all of them.
        let selectedCount = selection.contains(entry.id) ? selection.count : 0
        let removeFromPlaylist: FLContextMenuItem = selectedCount > 1
            ? .button("Remove \(selectedCount) Tracks from Playlist", systemImage: "minus.circle") {
                playlistStore.removeEntries(ids: selection, from: playlistID)
                selection = []
            }
            : .button("Remove from Playlist", systemImage: "minus.circle") {
                playlistStore.removeEntries(ids: [entry.id], from: playlistID)
                selection.remove(entry.id)
            }
        let menus = LibraryMenus(player: player, library: library, playlistStore: playlistStore, playlistAdd: playlistAdd, router: router)
        return menus.track(
            track,
            extra: [removeFromPlaylist],
            edit: { editingTrack = track },
            remove: { removalRequest = LibraryRemovalRequest(title: track.title, tracks: [track]) }
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text("No tracks in this playlist")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textTertiary)
            Text("Right-click tracks in your collection to add them")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xxl)
    }

    // MARK: - Helpers

    private typealias TrackLookup = (byPath: [String: Track], byID: [UUID: Track])

    private func buildTrackLookup() -> TrackLookup {
        let byPath = Dictionary(library.tracks.map { ($0.url.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        let byID   = Dictionary(library.tracks.map { ($0.id,       $0) },
                                uniquingKeysWith: { first, _ in first })
        return (byPath, byID)
    }

    /// Resolves a playlist entry to a live Track, preferring the stable
    /// `trackID` UUID (move-proof) and falling back to `relativePath` for
    /// legacy entries that pre-date UUID persistence.
    private func resolveEntry(_ entry: PlaylistEntry, lookup: TrackLookup) -> Track? {
        if let tid = entry.trackID, let track = lookup.byID[tid] { return track }
        guard let rootURL = library.rootURL else { return nil }
        let absolutePath = rootURL.appendingPathComponent(entry.relativePath).path
        return lookup.byPath[absolutePath]
    }

    private func playFromEntry(_ entry: PlaylistEntry, in playlist: Playlist) {
        let tracks = playlistStore.resolvedTracks(for: playlist, in: library)
        guard let entryIndex = playlist.entries.firstIndex(where: { $0.id == entry.id }) else { return }

        // Map the entry index to the resolved track index (accounting for any
        // unresolvable entries that compactMap skipped).
        var resolvedIndex = 0
        let lookup = buildTrackLookup()
        for i in 0..<entryIndex {
            if resolveEntry(playlist.entries[i], lookup: lookup) != nil {
                resolvedIndex += 1
            }
        }

        guard resolvedIndex < tracks.count else { return }
        player.startFreshQueue(tracks, startAt: resolvedIndex, source: playlist.name)
        player.engine.play()
        listening.recordPlaylistPlay(playlist)
    }

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            playlistStore.renamePlaylist(id: playlistID, name: trimmed)
        }
        isEditingName = false
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
