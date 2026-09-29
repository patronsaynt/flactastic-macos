import SwiftUI

/// Flat "All Tracks" view for the Collection tab. Shows every track in the
/// library as a sortable, searchable list, with Play All / Shuffle All buttons
/// that queue the entire (filtered + sorted) catalogue.
///
/// The parent `CollectionView` owns the search text, the mode toggle and the
/// sort state (so one control row serves every mode). This view owns the
/// Play All / Shuffle All buttons and the list.
struct AllTracksView: View {
    @Environment(PlayerState.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(NavigationRouter.self) private var router

    let tracks: [Track]
    let searchText: String
    /// Persisted by `CollectionView`, which renders the sort control.
    @Binding var sortOption: AllTracksSortOption
    @Binding var ascending: Bool

    @State private var editingTrack: Track? = nil
    @State private var removalRequest: LibraryRemovalRequest? = nil
    @State private var selection: Set<UUID> = []
    /// Anchor row for shift-click range selection.
    @State private var anchorID: UUID? = nil
    @State private var mergePayload: MergeSheetPayload? = nil
    /// Gates the initial bulk reveal — see `CollectionView.canAnimateEntrances`.
    @State private var canAnimateEntrances = false
    private var animatedTrackIDs: Binding<Set<UUID>> {
        Binding(get: { library.revealedTrackIDs }, set: { library.revealedTrackIDs = $0 })
    }

    /// Cached sorted+filtered track list. Recomputed only when the underlying
    /// inputs change (tracks, search text, sort option, direction) — NOT on
    /// every selection toggle. Without this cache, every tap would re-sort the
    /// entire library, producing seconds-long lag on large collections.
    @State private var cachedVisible: [Track] = []
    /// `cachedVisible` is only filled by `recomputeVisible()` from `.onAppear`,
    /// so the very first render always sees an empty list. Without this flag
    /// that frame would render the "no matches" state and then swap to the
    /// full list — a height change the mode-switch crossfade animates, which
    /// reads as the list lurching down from the top.
    @State private var hasComputed = false

    private func recomputeVisible() {
        let filtered: [Track]
        if searchText.isEmpty {
            filtered = tracks
        } else {
            let q = searchText.lowercased()
            filtered = tracks.filter { t in
                t.title.localizedCaseInsensitiveContains(q)
                    || (t.artist?.localizedCaseInsensitiveContains(q) ?? false)
                    || (t.album?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        cachedVisible = sorted(filtered, by: sortOption, ascending: ascending)
        hasComputed = true
    }

    var body: some View {
        // Branch on the *source* tracks, not the cache: this keeps the outer
        // layout identical from the first frame, so switching into Tracks
        // crossfades a stable shape instead of animating a height change.
        VStack(alignment: .leading, spacing: 0) {
            playControls
                .padding(.bottom, 18)

            if tracks.isEmpty {
                emptyState(message: "No tracks in your library")
            } else {
                FLTrackListHeader()
                trackList
            }
        }
        .task { canAnimateEntrances = true }
        .onAppear { recomputeVisible() }
        .onChange(of: tracks) { _, _ in recomputeVisible() }
        .onChange(of: searchText) { _, _ in recomputeVisible() }
        .onChange(of: sortOption) { _, _ in recomputeVisible() }
        .onChange(of: ascending) { _, _ in recomputeVisible() }
        .removeFromLibraryConfirmation($removalRequest, library: library)
        .sheet(item: $editingTrack) { track in
            TrackMetadataEditorView(track: track)
                .environment(library)
        }
        .sheet(item: $mergePayload) { payload in
            MergeTracksIntoAlbumView(tracks: payload.tracks) {
                clearSelection()
            }
            .environment(library)
        }
    }

    private struct MergeSheetPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    // MARK: - Play controls

    private var playControls: some View {
        HStack(spacing: 10) {
            Button { playAll(shuffle: false) } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                    Text("Play All")
                }
            }
            .buttonStyle(FLActionPillStyle(isPrimary: true))
            .disabled(cachedVisible.isEmpty)

            Button { playAll(shuffle: true) } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12))
                    Text("Shuffle All")
                }
            }
            .buttonStyle(FLActionPillStyle())
            .disabled(cachedVisible.isEmpty)
        }
    }

    // MARK: - Track list

    @ViewBuilder
    private var trackList: some View {
        ScrollView {
            // Lives inside the scroll view so toggling it can't resize the
            // container above it.
            if hasComputed && cachedVisible.isEmpty {
                emptyState(message: "No tracks match your search")
            } else {
                trackRows
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var trackRows: some View {
        Group {
            LazyVStack(spacing: 0) {
                ForEach(Array(cachedVisible.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        isPlaying: player.currentTrack?.id == track.id,
                        displayNumber: index + 1,
                        showAlbumArt: true,
                        showAlbumInSubtitle: true
                    )
                    .flRowStyle(fill: rowFill(for: track))
                    .onTapGesture(count: 2) { play(track: track) }
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded { handleSelection(for: track) }
                    )
                    .flContextMenu {
                        let tracksForMenu = contextTracks(primary: track)
                        playbackContextMenuItems(for: tracksForMenu, player: player)
                        FLContextMenuItem.divider
                        FLContextMenuItem.button("View Album", systemImage: "square.grid.2x2") {
                            if let albumID = library.album(for: track)?.id {
                                router.navigateToAlbum(id: albumID)
                            }
                        }
                        FLContextMenuItem.divider
                        if tracksForMenu.count >= 2 {
                            FLContextMenuItem.button("Merge into Album…") {
                                mergePayload = MergeSheetPayload(tracks: tracksForMenu)
                            }
                            FLContextMenuItem.divider
                        }
                        FLContextMenuItem.button("Edit...", systemImage: "pencil") { editingTrack = track }
                        FLContextMenuItem.button("Remove from Library", systemImage: "trash") { removalRequest = LibraryRemovalRequest(title: tracksForMenu.count == 1 ? track.title : "\(tracksForMenu.count) Tracks", tracks: tracksForMenu) }
                        FLContextMenuItem.divider
                        addToPlaylistMenuItem(tracks: tracksForMenu)
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
                    .riseFadeIn(index: index, animated: track.id, animatedIDs: animatedTrackIDs, enabled: canAnimateEntrances)
                }
            }
            .padding(.bottom, 100)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
            )
        }
    }

    /// Tracks the context menu should operate on. When the right-clicked track
    /// is part of an active multi-selection, include every selected track so
    /// "Merge into Album…" and other batch actions target the whole set.
    /// Otherwise the menu acts on the single right-clicked track.
    private func contextTracks(primary: Track) -> [Track] {
        if selection.count >= 2, selection.contains(primary.id) {
            let byID = Dictionary(uniqueKeysWithValues: cachedVisible.map { ($0.id, $0) })
            return selection.compactMap { byID[$0] }
        }
        return [primary]
    }

    private func handleSelection(for track: Track) {
        if NSEvent.modifierFlags.contains(.shift) {
            // Shift-click: extend selection from anchor (or current row if none)
            // to the clicked row.
            let anchor = anchorID ?? track.id
            guard let anchorIdx = cachedVisible.firstIndex(where: { $0.id == anchor }),
                  let clickedIdx = cachedVisible.firstIndex(where: { $0.id == track.id })
            else { return }
            let lo = min(anchorIdx, clickedIdx)
            let hi = max(anchorIdx, clickedIdx)
            selection = Set(cachedVisible[lo...hi].map(\.id))
            if anchorID == nil { anchorID = track.id }
        } else {
            // Plain click: select only this row and set it as the range anchor.
            selection = [track.id]
            anchorID = track.id
        }
    }

    private func clearSelection() {
        if !selection.isEmpty { selection = [] }
        anchorID = nil
    }

    /// Playing / selected rows carry their own fill; everything else falls
    /// through to `flRowStyle`'s hover fill.
    private func rowFill(for track: Track) -> Color? {
        if player.currentTrack?.id == track.id { return Theme.surfaceElevated }
        if selection.contains(track.id) { return Theme.surfaceElevated.opacity(0.55) }
        return nil
    }

    private func addToPlaylistMenuItem(tracks: [Track]) -> FLContextMenuItem {
        var children: [FLContextMenuItem] = []
        if !playlistStore.playlists.isEmpty {
            for playlist in playlistStore.playlists {
                children.append(.button(playlist.name) {
                    playlistAddCoordinator.request(
                        tracks: tracks,
                        playlistID: playlist.id,
                        playlistName: playlist.name,
                        rootURL: library.rootURL,
                        store: playlistStore
                    )
                })
            }
            children.append(.divider)
        }
        children.append(.textField("New playlist name…", systemImage: "plus") { name in
            playlistAddCoordinator.createPlaylistAndAdd(
                name: name,
                tracks: tracks,
                rootURL: library.rootURL,
                store: playlistStore
            )
        })
        return .submenu("Add to Playlist", systemImage: "plus.square.on.square", items: children)
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl)
    }

    // MARK: - Playback

    private func play(track: Track) {
        let queue = cachedVisible
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        player.startFreshQueue(queue, startAt: index, source: "Library")
        player.engine.play()
        clearSelection()
    }

    private func playAll(shuffle: Bool) {
        let queue = cachedVisible
        guard !queue.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let startIndex = shuffle ? Int.random(in: 0..<queue.count) : 0
        player.startFreshQueue(queue, startAt: startIndex, source: "Library")
        player.engine.play()
        clearSelection()
    }

    // MARK: - Sorting

    private func sorted(_ tracks: [Track],
                        by option: AllTracksSortOption,
                        ascending: Bool) -> [Track] {
        let result: [Track]
        switch option {
        case .songName:
            result = tracks.sorted { a, b in
                a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        case .artistName:
            result = tracks.sorted { a, b in
                let lhs = a.artist ?? ""
                let rhs = b.artist ?? ""
                if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        case .dateAdded:
            // Tracks missing a timestamp sort to the end regardless of order.
            result = tracks.sorted { a, b in
                switch (a.dateAdded, b.dateAdded) {
                case let (x?, y?): return x < y
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):   return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
        }
        return ascending ? result : result.reversed()
    }
}
