import SwiftUI

struct AlbumDetailView: View {
    let albumID: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(NavigationRouter.self) private var router
    @Environment(ListeningStore.self) private var listening

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

    var body: some View {
        if let album {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FLBackLink(title: router.collectionBackTitle) {
                            router.goBackInCollection()
                        }
                        .padding(.top, 24)

                        albumHeader(album)
                            .padding(.top, 22)
                            .padding(.bottom, 28)

                        FLTrackListHeader()
                        trackList(album.tracks)
                    }
                    .padding(.horizontal, collectionGutter)
                    .padding(.bottom, 100)
                }
            }
            .background(Theme.background)
            .sheet(isPresented: $isEditingAlbum) {
                AlbumMetadataEditorView(album: album)
                    .environment(library)
            }
            .removeFromLibraryConfirmation($removalRequest, library: library)
            .sheet(item: $editingTrack) { track in
                TrackMetadataEditorView(track: track)
                    .environment(library)
            }
            .onAppear {
                knownTrackIDs = Set(album.tracks.map(\.id))
            }
            .onChange(of: album.tracks.map(\.id)) { _, ids in
                knownTrackIDs = Set(ids)
            }
        } else {
            Text("Album not found")
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
    }

    // MARK: - Album Header

    private func albumHeader(_ album: Album) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(data: album.artwork, size: 180, id: "album:\(album.id)")
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        router.artworkZoomData = album.artwork
                    }
                }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

            VStack(alignment: .leading, spacing: 0) {
                FLEyebrow(text: album.isMixCompilation ? "Mix Compilation" : "Album")

                Text(album.name)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 6)

                metadataLine(album)
                    .padding(.top, 8)

                HStack(spacing: 10) {
                    Button {
                        playAlbum(album, shuffle: false)
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("Play")
                        }
                    }
                    .buttonStyle(FLActionPillStyle(isPrimary: true))

                    Button {
                        playAlbum(album, shuffle: true)
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 12))
                            Text("Shuffle")
                        }
                    }
                    .buttonStyle(FLActionPillStyle())

                    FLCircleIconButton(systemImage: "pencil") {
                        isEditingAlbum = true
                    }
                    .help("Edit album")
                }
                .padding(.top, 18)
            }
        }
    }

    /// `artist · year · genre · N tracks · duration` — replaces the old row of
    /// metadata chips. The artist segment stays clickable.
    private func metadataPieces(_ album: Album) -> [String] {
        var trailing: [String] = []
        if let year = album.year { trailing.append("\(year)") }
        if let genre = album.genre { trailing.append(genre) }
        trailing.append(contentsOf: album.secondaryGenres)
        trailing.append("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
        trailing.append(FormatUtils.formatDuration(album.totalDuration))
        return trailing
    }

    @ViewBuilder
    private func metadataLine(_ album: Album) -> some View {
        HStack(spacing: 0) {
            if album.isCompilation {
                Text("Compilation")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ArtistLink(
                    credit: album.artist,
                    font: .system(size: 13.5),
                    color: Theme.textSecondary
                )
            }

            ForEach(Array(metadataPieces(album).enumerated()), id: \.offset) { _, piece in
                Text(" · \(piece)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .lineLimit(1)
    }

    // MARK: - Track List

    private func trackList(_ tracks: [Track]) -> some View {
        // Lazy so a 100-track box set doesn't instantiate every TrackRow
        // (each with artwork) eagerly — rows materialize as they scroll in.
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, isPlaying: player.currentTrack?.id == track.id)
                    .flRowStyle(fill: player.currentTrack?.id == track.id ? Theme.surfaceElevated : nil)
                    .onTapGesture(count: 2) {
                        player.startFreshQueue(tracks, startAt: index, source: album?.name)
                        player.engine.play()
                        if let album { listening.recordAlbumPlay(album) }
                    }
                    .flContextMenu {
                        playbackContextMenuItems(for: [track], player: player)
                        FLContextMenuItem.divider
                        FLContextMenuItem.button("Edit...", systemImage: "pencil") { editingTrack = track }
                        FLContextMenuItem.button("Remove from Library", systemImage: "trash") { removalRequest = LibraryRemovalRequest(title: track.title, tracks: [track]) }
                        FLContextMenuItem.divider
                        addToPlaylistMenuItem(track: track)
                        let artistItems = artistContextMenuItems(
                            credit: track.artist ?? track.albumArtist,
                            library: library,
                            router: router
                        )
                        if !artistItems.isEmpty {
                            FLContextMenuItem.divider
                            artistItems
                        }
                    }
                    .riseFadeIn(index: index)
            }
        }
    }

    private func addToPlaylistMenuItem(track: Track) -> FLContextMenuItem {
        let newItem: FLContextMenuItem = .textField("New playlist name…", systemImage: "plus") { name in
            playlistAddCoordinator.createPlaylistAndAdd(
                name: name,
                tracks: [track],
                rootURL: library.rootURL,
                store: playlistStore
            )
        }
        var children: [FLContextMenuItem] = []
        if !playlistStore.playlists.isEmpty {
            for playlist in playlistStore.playlists {
                children.append(.button(playlist.name) {
                    playlistAddCoordinator.request(
                        tracks: [track],
                        playlistID: playlist.id,
                        playlistName: playlist.name,
                        rootURL: library.rootURL,
                        store: playlistStore
                    )
                })
            }
            children.append(.divider)
        }
        children.append(newItem)
        return .submenu("Add to Playlist", systemImage: "plus.square.on.square", items: children)
    }

    private func playAlbum(_ album: Album, shuffle: Bool) {
        player.isShuffleEnabled = shuffle
        let startIndex = shuffle ? Int.random(in: 0..<album.tracks.count) : 0
        player.startFreshQueue(album.tracks, startAt: startIndex, source: album.name)
        player.engine.play()
        listening.recordAlbumPlay(album)
    }
}
