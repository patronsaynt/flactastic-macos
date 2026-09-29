import SwiftUI

/// Horizontal gutter for the redesigned Collection surfaces.
let collectionGutter: CGFloat = 36

/// Headroom reserved at the top of a scrolling card grid. A hovered card rises
/// 3pt and scales 1.03, pushing its top edge above the scroll content's origin
/// — and `ScrollView` clips to its bounds, so without this the first row's
/// cards get their tops shaved. The control row above gives up the same amount
/// of bottom padding, keeping the resting gap identical.
let cardHoverHeadroom: CGFloat = 8

struct CollectionView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(Settings.self) private var settings
    @Environment(NavigationRouter.self) private var router

    @State private var searchText = ""
    /// Persisted across launches so the user's preferred grouping (e.g.
    /// "Artist") survives quitting the app. Default stays `.album` for
    /// first-time users.
    @AppStorage("flactastic.collectionSort") private var sortOption: CollectionSortOption = .album
    /// Track sort state lives here rather than in `AllTracksView` so the single
    /// control row under the page title can drive every content mode.
    @AppStorage("flactastic.allTracksSort") private var tracksSortOption: AllTracksSortOption = .dateAdded
    /// `false` for `.dateAdded` means newest-first. Alphabetical sorts flip the
    /// default to ascending when the option changes.
    @AppStorage("flactastic.allTracksAscending") private var tracksAscending: Bool = false
    @State private var contentMode: CollectionContentMode = .albums
    @State private var editingAlbum: Album? = nil
    @State private var removalRequest: LibraryRemovalRequest? = nil
    @State private var refreshRotation: Double = 0
    /// Gates the *initial* bulk reveal of the album grid/list for this
    /// mount: starts `false` so the first synchronous render of however
    /// many cells populate at once shows instantly (animating dozens of
    /// cells simultaneously is itself a source of stutter), then flips
    /// `true` shortly after so anything appearing from then on (search
    /// results, continued scrolling) still gets the fade. Per-item replay
    /// prevention lives on `library.revealedAlbumIDs` instead of local
    /// state, since this view gets fully remounted on every tab switch.
    @State private var canAnimateEntrances = false
    private var animatedAlbumIDs: Binding<Set<String>> {
        Binding(get: { library.revealedAlbumIDs }, set: { library.revealedAlbumIDs = $0 })
    }

    /// Cached sorted+filtered (and, for artist/genre sorts, grouped) album
    /// lists. Recomputed only when the underlying inputs change — NOT on every
    /// body evaluation. Sorting with `localizedStandardCompare` inside `body`
    /// re-sorted the whole library on every render (hover, selection, any
    /// observable tick). Same pattern as `AllTracksView.cachedVisible`.
    @State private var cachedFiltered: [Album] = []
    @State private var cachedGroups: [(key: String, albums: [Album])] = []

    private func recomputeVisible() {
        let albums = library.albums
        let sorted: [Album]
        switch sortOption {
        case .album:
            sorted = albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .artist:
            sorted = albums.sorted {
                ($0.artist ?? "").localizedStandardCompare($1.artist ?? "") == .orderedAscending
            }
        case .year:
            sorted = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .genre:
            sorted = albums.sorted {
                ($0.genre ?? "Unknown").localizedStandardCompare($1.genre ?? "Unknown") == .orderedAscending
            }
        }

        let filtered: [Album]
        if searchText.isEmpty {
            filtered = sorted
        } else {
            let query = searchText.lowercased()
            filtered = sorted.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) ||
                $0.tracks.contains { $0.title.localizedCaseInsensitiveContains(query) }
            }
        }
        cachedFiltered = filtered

        switch sortOption {
        case .artist:
            let grouped = Dictionary(grouping: filtered) { $0.artist ?? "Unknown Artist" }
            cachedGroups = grouped.map { (key: $0.key, albums: $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        case .genre:
            let grouped = Dictionary(grouping: filtered) { $0.genre ?? "Unknown" }
            cachedGroups = grouped.map { (key: $0.key, albums: $0.value) }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        default:
            cachedGroups = []
        }
    }

    private var isRefreshing: Bool {
        library.scanState == .refreshing || library.scanState == .scanning
    }

    private var shouldGroup: Bool {
        sortOption == .genre || (sortOption == .artist && settings.groupByArtist)
    }

    var body: some View {
        // Manual navigation (no NavigationStack): a NavigationStack on macOS
        // routes its back button through the window toolbar, which can't
        // coexist with the custom top bar. The detail for the top of
        // `router.collectionPath` is shown in place; `DetailBackButton` pops it.
        Group {
            if let top = router.collectionPath.last {
                detailView(for: top)
                    .transition(.opacity)
            } else {
                rootContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: router.collectionPath)
        .onAppear { recomputeVisible() }
        .onChange(of: library.tracksRevision) { _, _ in recomputeVisible() }
        .onChange(of: searchText) { _, _ in recomputeVisible() }
        .onChange(of: sortOption) { _, _ in recomputeVisible() }
        .removeFromLibraryConfirmation($removalRequest, library: library)
        .sheet(item: $editingAlbum) { album in
            AlbumMetadataEditorView(album: album)
                .environment(library)
        }
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            // Title + control row are always pinned above the content area.
            VStack(alignment: .leading, spacing: 0) {
                FLPageHeader(eyebrow: "Library", title: modeTitle) {
                    refreshButton
                }
                .padding(.top, 30)

                controlRow
                    .padding(.top, 18)
                    .padding(.bottom, 20 - cardHoverHeadroom)
            }
            .padding(.horizontal, collectionGutter)

            // Crossfade between modes (and between grid/list) rather than
            // hard-cutting — the pill toggle animates, so the content should
            // too. Same easing as the root ⇄ detail transition.
            Group {
                switch contentMode {
                case .albums:
                    // Albums use a ScrollView so the grid/list can grow freely.
                    ScrollView {
                        Group {
                            if shouldGroup {
                                groupedContent
                            } else if settings.useListLayout {
                                albumList(cachedFiltered)
                            } else {
                                albumGrid(cachedFiltered)
                            }
                        }
                        .transition(.opacity)
                        .padding(.horizontal, collectionGutter)
                        .padding(.top, cardHoverHeadroom)
                        .padding(.bottom, 100)
                    }
                    .task { canAnimateEntrances = true }
                case .artists:
                    ArtistsCollectionView(searchText: searchText)
                case .tracks:
                    AllTracksView(
                        tracks: library.tracks,
                        searchText: searchText,
                        sortOption: $tracksSortOption,
                        ascending: $tracksAscending
                    )
                    .padding(.horizontal, collectionGutter)
                    .padding(.top, cardHoverHeadroom)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.22), value: settings.useListLayout)
        }
        .animation(.easeInOut(duration: 0.22), value: contentMode)
        .background(Theme.background)
    }

    @ViewBuilder
    private func detailView(for value: String) -> some View {
        if let artistKey = NavigationRoute.artistKey(from: value) {
            ArtistDetailView(artistKey: artistKey)
        } else {
            AlbumDetailView(albumID: value)
        }
    }

    // MARK: - Header

    private var modeTitle: String {
        switch contentMode {
        case .albums:  return "Albums"
        case .artists: return "Artists"
        case .tracks:  return "All Tracks"
        }
    }

    private var refreshButton: some View {
        FLCircleIconButton {
            library.refreshLibrary()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(refreshRotation))
        }
        .disabled(isRefreshing)
        .help("Refresh Library")
        .onChange(of: isRefreshing) { _, spinning in
            if spinning {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    refreshRotation = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    refreshRotation = 0
                }
            }
        }
    }

    /// Grid/list preference is the persisted app-wide one, now driven from the
    /// page itself rather than a Settings toggle.
    private var useListLayout: Binding<Bool> {
        Binding(get: { settings.useListLayout }, set: { settings.useListLayout = $0 })
    }

    private var controlRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            FLPillToggle(
                selection: $contentMode,
                segments: [
                    .text(.albums, "Albums"),
                    .text(.artists, "Artists"),
                    .text(.tracks, "Tracks"),
                ]
            )

            if contentMode == .albums {
                FLPillToggle(
                    selection: useListLayout,
                    segments: [
                        .icon(false, "square.grid.2x2", help: "Grid"),
                        .icon(true, "list.bullet", help: "List"),
                    ]
                )
            }

            Spacer()

            switch contentMode {
            case .albums:
                FLSortMenu(
                    selection: $sortOption,
                    options: CollectionSortOption.allCases
                ) { $0.rawValue }
            case .tracks:
                FLSortMenu(
                    selection: $tracksSortOption,
                    options: AllTracksSortOption.allCases
                ) { $0.rawValue }
                .onChange(of: tracksSortOption) { _, newValue in
                    // Reset direction to the sensible default for the chosen sort.
                    tracksAscending = (newValue != .dateAdded)
                }

                FLCircleIconButton(systemImage: tracksAscending ? "arrow.up" : "arrow.down") {
                    tracksAscending.toggle()
                }
                .help(tracksAscending ? "Ascending" : "Descending")
            case .artists:
                EmptyView()
            }

            SearchBarView(searchText: $searchText, style: .capsule)
        }
    }

    // MARK: - Grouped Content

    private var groupedContent: some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            ForEach(cachedGroups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        FLEyebrow(text: group.key)

                        Rectangle()
                            .fill(Theme.divider)
                            .frame(height: 1)

                        Text("\(group.albums.count) album\(group.albums.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if settings.useListLayout {
                        albumList(group.albums)
                    } else {
                        albumGrid(group.albums)
                    }
                }
            }
        }
    }

    // MARK: - Album Grid

    private func albumGrid(_ albums: [Album]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)],
            spacing: 24
        ) {
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                AlbumCardView(album: album)
                    .contentShape(Rectangle())
                    .onTapGesture { router.collectionPath.append(album.id) }
                    .flContextMenu { albumContextMenu(album) }
                    .riseFadeIn(index: index, animated: album.id, animatedIDs: animatedAlbumIDs, enabled: canAnimateEntrances)
            }
        }
    }

    // MARK: - Album List

    private func albumList(_ albums: [Album]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                AlbumRowView(album: album)
                    .onTapGesture { router.collectionPath.append(album.id) }
                    .flContextMenu { albumContextMenu(album) }
                    .riseFadeIn(index: index, animated: album.id, animatedIDs: animatedAlbumIDs, enabled: canAnimateEntrances)
            }
        }
    }

    private func albumContextMenu(_ album: Album) -> [FLContextMenuItem] {
        var items = playbackContextMenuItems(for: album.tracks, player: player)
        items.append(.divider)
        items.append(.button("Edit...", systemImage: "pencil") { editingAlbum = album })
        items.append(.button("Remove from Library", systemImage: "trash") {
            removalRequest = LibraryRemovalRequest(title: album.name, tracks: album.tracks)
        })
        if !album.isCompilation {
            let artistItems = artistContextMenuItems(
                credit: album.albumArtist ?? album.artist,
                library: library,
                router: router
            )
            if !artistItems.isEmpty {
                items.append(.divider)
                items.append(contentsOf: artistItems)
            }
        }
        return items
    }
}
