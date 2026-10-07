import SwiftUI

enum PlaylistSortOption: String, CaseIterable, Identifiable {
    case recentlyPlayed = "Recently Played"
    case nameAsc = "A–Z"
    case nameDesc = "Z–A"
    case newest = "Newest"

    var id: String { rawValue }
}

/// The Playlists tab: the running order of playlists on the left, each with
/// its cover, and the chosen one on a stage to the right, ready to play.
/// Double-clicking a playlist, or Open, goes to its full page.
struct PlaylistsTabView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(ListeningStore.self) private var listening
    @Environment(NavigationRouter.self) private var router

    @State private var searchText = ""
    @AppStorage("flactastic.playlistSort") private var sortOption: PlaylistSortOption = .recentlyPlayed
    /// Kept across launches and tab switches, so the stage shows the same
    /// playlist when you come back.
    @AppStorage("flactastic.selectedPlaylist") private var selectedIDString = ""
    @State private var showNewPlaylistPrompt = false
    @State private var newPlaylistName = ""
    @State private var editingPlaylistID: UUID?
    /// Each playlist's resolved tracks, built once per change to the
    /// playlists or the library rather than on every render: resolving
    /// walks the whole library.
    @State private var resolved: [UUID: [Track]] = [:]

    private static let indexWidth: CGFloat = 380

    var body: some View {
        // Manual navigation (no NavigationStack) — see CollectionView for why.
        Group {
            if let playlistID = router.playlistsPath.last {
                PlaylistDetailView(playlistID: playlistID)
                    .transition(.opacity)
            } else {
                rootContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: router.playlistsPath)
        .onAppear { resolveAll() }
        .onChange(of: playlistStore.revision) { resolveAll() }
        .onChange(of: library.tracksRevision) { resolveAll() }
        .sheet(isPresented: $showNewPlaylistPrompt) {
            newPlaylistSheet
        }
        .sheet(item: $editingPlaylistID) { playlistID in
            PlaylistEditorView(playlistID: playlistID)
        }
    }

    // MARK: - Data

    private func resolveAll() {
        resolved = playlistStore.resolvedTracksForAll(in: library)
    }

    private var visiblePlaylists: [Playlist] {
        let all = playlistStore.playlists
        let sorted: [Playlist]
        switch sortOption {
        case .recentlyPlayed:
            // Most recently played first; never-played playlists follow,
            // newest first.
            var recency: [String: Int] = [:]
            for (index, context) in listening.recentContexts.enumerated() where context.kind == .playlist {
                recency[context.targetID] = index
            }
            sorted = all.sorted { a, b in
                let ra = recency[a.id.uuidString], rb = recency[b.id.uuidString]
                switch (ra, rb) {
                case let (x?, y?): return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.dateCreated > b.dateCreated
                }
            }
        case .nameAsc:
            sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDesc:
            sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .newest:
            sorted = all.sorted { $0.dateCreated > $1.dateCreated }
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func cover(for playlist: Playlist) -> (data: Data?, id: String?) {
        if let custom = playlist.customArtwork {
            return (custom, "playlist:\(playlist.id):\(custom.count)")
        }
        // No id: the cache keys first-track art by content, so it's shared
        // with every other view of the same album cover.
        return (resolved[playlist.id]?.first?.artwork, nil)
    }

    // MARK: - Layout

    private var rootContent: some View {
        let playlists = visiblePlaylists
        let selected = playlists.first { $0.id.uuidString == selectedIDString } ?? playlists.first

        return HStack(alignment: .top, spacing: 24) {
            index(playlists, selected: selected)
                .frame(width: Self.indexWidth)

            Group {
                if let selected {
                    PlaylistStage(
                        playlist: selected,
                        tracks: resolved[selected.id] ?? [],
                        cover: cover(for: selected),
                        open: { router.playlistsPath.append(selected.id) },
                        edit: { editingPlaylistID = selected.id }
                    )
                    .id(selected.id)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                } else {
                    emptyStage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32), value: selected?.id)
        }
        .padding(.leading, collectionGutter - 12)
        .padding(.trailing, collectionGutter - 8)
        .padding(.top, 28 + topBarInset)
        .padding(.bottom, 20)
        .background(Theme.background)
    }

    // MARK: - Index

    private func index(_ playlists: [Playlist], selected: Playlist?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Text("Playlists")
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-1.4)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                FLCircleIconButton {
                    newPlaylistName = ""
                    showNewPlaylistPrompt = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .help("New Playlist")
                .accessibilityLabel("New Playlist")
            }
            .padding(.horizontal, 12)

            HStack(spacing: Theme.Spacing.sm) {
                SearchBarView(searchText: $searchText, style: .capsule)
                FLSortMenu(selection: $sortOption, options: PlaylistSortOption.allCases) { $0.rawValue }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if playlists.isEmpty {
                Text(searchText.isEmpty ? "No playlists yet" : "No playlists match your search")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(playlists) { playlist in
                            let cover = cover(for: playlist)
                            PlaylistIndexRow(
                                name: playlist.name,
                                trackCount: resolved[playlist.id]?.count ?? playlist.entries.count,
                                cover: cover.data,
                                coverID: cover.id,
                                isSelected: playlist.id == selected?.id
                            )
                            .onTapGesture(count: 2) { router.playlistsPath.append(playlist.id) }
                            .simultaneousGesture(TapGesture().onEnded {
                                selectedIDString = playlist.id.uuidString
                            })
                            .flContextMenu { playlistContextMenu(playlist) }
                        }
                    }
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var emptyStage: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Make a playlist to get started")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
            Button {
                newPlaylistName = ""
                showNewPlaylistPrompt = true
            } label: {
                Label("New Playlist", systemImage: "plus")
            }
            .buttonStyle(FLActionPillStyle(isPrimary: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
    }

    private func playlistContextMenu(_ playlist: Playlist) -> [FLContextMenuItem] {
        var items = playbackContextMenuItems(for: resolved[playlist.id] ?? [], player: player)
        items.append(.divider)
        items.append(.button("Open", systemImage: "arrow.up.right") { router.playlistsPath.append(playlist.id) })
        items.append(.button("Edit…", systemImage: "pencil") { editingPlaylistID = playlist.id })
        items.append(.divider)
        items.append(.button("Delete", destructive: true) {
            playlistStore.deletePlaylist(id: playlist.id)
        })
        return items
    }

    // MARK: - New Playlist Sheet

    private var newPlaylistSheet: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Text("New Playlist")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textPrimary)

            TextField("Playlist name", text: $newPlaylistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitNewPlaylist() }

            HStack(spacing: Theme.Spacing.md) {
                Button("Cancel") {
                    showNewPlaylistPrompt = false
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    commitNewPlaylist()
                }
                .buttonStyle(PillButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 340, height: 160)
        .background(Theme.surface)
    }

    // MARK: - Actions

    private func commitNewPlaylist() {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let playlist = playlistStore.createPlaylist(name: trimmed)
        selectedIDString = playlist.id.uuidString
        showNewPlaylistPrompt = false
    }
}

// MARK: - Index row

/// One playlist in the running order: its cover, its name in display type,
/// and how many tracks it holds. The chosen one reads bright.
private struct PlaylistIndexRow: View {
    let name: String
    let trackCount: Int
    let cover: Data?
    let coverID: String?
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(data: cover, size: 48, id: coverID)
                .opacity(isSelected || isHovering ? 1 : 0.7)

            Text(name)
                .font(.system(size: 24, weight: .heavy))
                .tracking(-0.7)
                .foregroundStyle(isSelected ? Theme.textPrimary : (isHovering ? Theme.textSecondary : Theme.textTertiary))
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            Text("\(trackCount)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Theme.surfaceElevated : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(trackCount) tracks")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Stage

/// The chosen playlist, ready to play: a hero on a blurred wash of its
/// cover, then its tracks.
private struct PlaylistStage: View {
    let playlist: Playlist
    let tracks: [Track]
    let cover: (data: Data?, id: String?)
    let open: () -> Void
    let edit: () -> Void

    @Environment(PlayerState.self) private var player
    @Environment(ListeningStore.self) private var listening
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationRouter.self) private var router
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAdd
    @Environment(\.colorScheme) private var colorScheme

    @State private var backdrop: NSImage?
    @State private var editingTrack: Track?
    @State private var removalRequest: LibraryRemovalRequest?

    private var isLight: Bool { colorScheme == .light }
    private var ink: Color { isLight ? Theme.textPrimary : .white }
    private var inkSecondary: Color { isLight ? Color(white: 0.28) : .white.opacity(0.82) }
    private var backdropID: String {
        "playlist-stage:\(cover.id ?? cover.data.map(ArtworkImageCache.contentID(for:)) ?? playlist.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            trackList
        }
        .background {
            ZStack(alignment: .top) {
                Theme.surface
                backdropLayer
                    .frame(height: 300)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Theme.surface.opacity(0.4), location: 0.34),
                        .init(color: Theme.surface, location: 0.52),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 580)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sheet(item: $editingTrack) { track in
            TrackMetadataEditorView(track: track)
                .environment(library)
        }
        .removeFromLibraryConfirmation($removalRequest, library: library)
        .task(id: backdropID) {
            backdrop = BlurredArtworkCache.shared.cached(id: backdropID)
            if backdrop == nil {
                backdrop = await BlurredArtworkCache.shared.image(for: cover.data, id: backdropID).image
            }
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
                        .scaleEffect(1.3)
                        .saturation(1.4)
                        .brightness(isLight ? 0.18 : -0.22)
                }
            }
            .clipped()
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(data: cover.data, size: 200, id: cover.id)
                .shadow(color: .black.opacity(isLight ? 0.25 : 0.6), radius: 24, y: 18)
                .flContextMenu {
                    playbackContextMenuItems(for: tracks, player: player)
                    FLContextMenuItem.divider
                    FLContextMenuItem.button("Open", systemImage: "arrow.up.right", action: open)
                    FLContextMenuItem.button("Edit...", systemImage: "pencil", action: edit)
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(playlist.name)
                    .font(.system(size: 56, weight: .heavy))
                    .tracking(-2.2)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 14))
                        .foregroundStyle(inkSecondary)
                        .lineLimit(2)
                        .padding(.top, 8)
                }

                HStack(spacing: 14) {
                    Text(FormatUtils.playlistSummary(
                        trackCount: tracks.count,
                        duration: tracks.reduce(0) { $0 + ($1.duration ?? 0) }
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(inkSecondary)
                    if !tracks.isEmpty {
                        QualityMixBar(tracks: tracks, width: 160, ink: inkSecondary)
                    }
                }
                .padding(.top, 10)

                HStack(spacing: Theme.Spacing.md) {
                    if !tracks.isEmpty {
                        Button { play(from: 0, shuffle: false) } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(HeroPillStyle(kind: .primary, ink: ink, isLight: isLight))
                        Button { play(from: 0, shuffle: true) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                    }
                    Button(action: edit) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                    .help("Edit cover, name and description")
                    .accessibilityLabel("Edit playlist")

                    Spacer(minLength: Theme.Spacing.md)

                    Button(action: open) {
                        Label("Open", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                    .help("Open the full playlist")
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var trackList: some View {
        if tracks.isEmpty {
            VStack(spacing: Theme.Spacing.sm) {
                Text("No tracks in this playlist")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Right-click tracks in your collection to add them")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        StageTrackRow(
                            track: track,
                            number: index + 1,
                            isCurrent: player.currentTrack?.id == track.id,
                            play: { play(from: index, shuffle: false) }
                        )
                        .flContextMenu { trackMenu(track, at: index) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func trackMenu(_ track: Track, at index: Int) -> [FLContextMenuItem] {
        let menus = LibraryMenus(player: player, library: library, playlistStore: playlistStore, playlistAdd: playlistAdd, router: router)
        let removeFromPlaylist: FLContextMenuItem = .button("Remove from Playlist", systemImage: "minus.circle") {
            if let entryID = entryID(at: index) {
                playlistStore.removeEntries(ids: [entryID], from: playlist.id)
            }
        }
        return menus.track(
            track,
            extra: [removeFromPlaylist],
            edit: { editingTrack = track },
            remove: { removalRequest = LibraryRemovalRequest(title: track.title, tracks: [track]) }
        )
    }

    /// The playlist entry behind the row at `index`. The rows skip entries
    /// whose files are gone, so this counts this track's earlier rows to
    /// pick the right entry when it appears more than once.
    private func entryID(at index: Int) -> UUID? {
        let track = tracks[index]
        let occurrence = tracks[..<index].filter { $0.id == track.id }.count
        let matches = playlist.entries.filter { $0.trackID == track.id }
        return occurrence < matches.count ? matches[occurrence].id : matches.first?.id
    }

    private func play(from index: Int, shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let start = shuffle ? Int.random(in: 0..<tracks.count) : index
        player.startFreshQueue(tracks, startAt: start, source: playlist.name)
        player.engine.play()
        listening.recordPlaylistPlay(playlist)
    }
}

/// A track on the stage: number (play on hover), cover, title with artist
/// and album, quality badge, length.
private struct StageTrackRow: View {
    let track: Track
    let number: Int
    let isCurrent: Bool
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Group {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                    } else if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")

            ArtworkView(data: track.artwork, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                Text([ArtistResolver.displayString(track.artist ?? track.albumArtist), track.album]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.md)

            TrackQualityBadge(track: track)

            Text(FormatUtils.formatDuration(track.duration))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: TrackRow.lengthColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? Theme.surfaceElevated : (isHovering ? Theme.surfaceElevated.opacity(0.6) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: play)
    }
}

// MARK: - Make UUID work with .sheet(item:)

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
