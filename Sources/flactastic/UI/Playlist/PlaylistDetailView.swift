import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID

    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(NavigationRouter.self) private var router
    @Environment(ListeningStore.self) private var listening

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var selection: Set<UUID> = []
    @State private var showEditor = false
    @State private var draggingEntryID: UUID? = nil
    @State private var dropTargetEntryID: UUID? = nil

    private var playlist: Playlist? {
        playlistStore.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        if let playlist {
            let tracks = playlistStore.resolvedTracks(for: playlist, in: library)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FLBackLink(title: router.playlistsBackTitle) {
                        router.goBackInPlaylists()
                    }
                    .padding(.top, 24)

                    playlistHeader(playlist, tracks: tracks)
                        .padding(.top, 22)
                        .padding(.bottom, 28)

                    if tracks.isEmpty {
                        emptyState
                    } else {
                        FLTrackListHeader(showDragHandle: true)
                        trackList(playlist)
                    }
                }
                .padding(.horizontal, collectionGutter)
                .padding(.bottom, 100)
            }
            .background(Theme.background)
            .sheet(isPresented: $showEditor) {
                PlaylistEditorView(playlistID: playlistID)
            }
        } else {
            Text("Playlist not found")
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func playlistHeader(_ playlist: Playlist, tracks: [Track]) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(data: playlist.customArtwork ?? tracks.first?.artwork, size: 180)

            VStack(alignment: .leading, spacing: 0) {
                FLEyebrow(text: "Playlist")

                Group {
                    if isEditingName {
                        TextField("Playlist name", text: $editedName)
                            .textFieldStyle(.plain)
                            .onSubmit { commitRename() }
                    } else {
                        Text(playlist.name)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                editedName = playlist.name
                                isEditingName = true
                            }
                            .help("Double-click to rename")
                    }
                }
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 6)

                Text(FormatUtils.playlistSummary(
                    trackCount: tracks.count,
                    duration: tracks.reduce(0) { $0 + ($1.duration ?? 0) }
                ))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)

                if let desc = playlist.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                HStack(spacing: 10) {
                    if !tracks.isEmpty {
                        Button {
                            player.isShuffleEnabled = false
                            player.startFreshQueue(tracks, startAt: 0, source: playlist.name)
                            player.engine.play()
                            listening.recordPlaylistPlay(playlist)
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                Text("Play")
                            }
                        }
                        .buttonStyle(FLActionPillStyle(isPrimary: true))

                        Button {
                            player.isShuffleEnabled = true
                            let startIndex = Int.random(in: 0..<tracks.count)
                            player.startFreshQueue(tracks, startAt: startIndex, source: playlist.name)
                            player.engine.play()
                            listening.recordPlaylistPlay(playlist)
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 12))
                                Text("Shuffle")
                            }
                        }
                        .buttonStyle(FLActionPillStyle())
                    }

                    FLCircleIconButton(systemImage: "pencil") {
                        showEditor = true
                    }
                    .help("Edit cover, name and description")
                }
                .padding(.top, 18)
            }
        }
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
        var items = playbackContextMenuItems(for: [track], player: player)
        items.append(.divider)
        items.append(.button("View Album", systemImage: "square.grid.2x2") {
            if let albumID = library.album(for: track)?.id {
                router.navigateToAlbum(id: albumID)
            }
        })
        let artistItems = artistContextMenuItems(
            credit: track.artist ?? track.albumArtist,
            library: library,
            router: router
        )
        items.append(contentsOf: artistItems)
        items.append(.divider)

        let selectedCount = selection.contains(entry.id) ? selection.count : 0
        if selectedCount > 1 {
            items.append(.button("Remove \(selectedCount) Tracks", systemImage: "minus.circle") {
                playlistStore.removeEntries(ids: selection, from: playlistID)
                selection = []
            })
        } else {
            items.append(.button("Remove from Playlist", systemImage: "minus.circle") {
                playlistStore.removeEntries(ids: [entry.id], from: playlistID)
                selection.remove(entry.id)
            })
        }
        return items
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
