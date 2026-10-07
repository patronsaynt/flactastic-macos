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
    @Environment(\.topBarInset) private var topBarInset
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(NavigationRouter.self) private var router
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAdd

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
    @AppStorage("flactastic.collectionAlbumView") private var albumViewStyle: AlbumViewStyle = .shelf
    @AppStorage("flactastic.artistSort") private var artistSort: ArtistSortOption = .mostReleases
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

    /// Cached sorted+filtered album list. Recomputed only when the underlying
    /// inputs change — NOT on every body evaluation. Sorting with
    /// `localizedStandardCompare` inside `body` re-sorted the whole library on
    /// every render (hover, selection, any observable tick). Same pattern as
    /// `AllTracksView.cachedVisible`.
    @State private var cachedFiltered: [Album] = []

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
    }

    /// Room kept free under the shelf's details for the floating player bar.
    private static let shelfBottomClearance: CGFloat = 104

    private var isRefreshing: Bool {
        library.scanState == .refreshing || library.scanState == .scanning
    }

    var body: some View {
        // Manual navigation (no NavigationStack): a NavigationStack on macOS
        // routes its back button through the window toolbar, which can't
        // coexist with the custom top bar. The detail for the top of
        // `router.collectionPath` is shown in place; its back button pops it.
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
            header
                .padding(.horizontal, collectionGutter)
                .padding(.top, 28 + topBarInset)
                .padding(.bottom, 12)

            // Crossfade between sections and views rather than hard-cutting.
            Group {
                switch contentMode {
                case .albums:
                    albumsContent
                case .artists:
                    ArtistsCollectionView(searchText: searchText, sort: artistSort)
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
        }
        .animation(.easeInOut(duration: 0.22), value: contentMode)
        .animation(.easeInOut(duration: 0.22), value: albumViewStyle)
        .background(Theme.background)
    }

    @ViewBuilder
    private var albumsContent: some View {
        if cachedFiltered.isEmpty {
            Text(searchText.isEmpty ? "No albums in your library" : "No albums match your search")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, collectionGutter)
                .padding(.top, 24)
        } else {
            switch albumViewStyle {
            case .shelf:
                // The shelf sizes its covers to fill the space below the
                // header, so it isn't wrapped in a vertical scroll view.
                GeometryReader { geo in
                    AlbumShelfView(
                        albums: cachedFiltered,
                        sort: sortOption,
                        available: CGSize(width: geo.size.width, height: geo.size.height - Self.shelfBottomClearance),
                        open: { router.collectionPath.append($0.id) },
                        contextMenu: albumContextMenu
                    )
                    .padding(.top, 8)
                }
                .transition(Self.shelfTransition)
            case .grid:
                ScrollView {
                    albumGrid(cachedFiltered)
                        .padding(.horizontal, collectionGutter)
                        .padding(.top, cardHoverHeadroom)
                        .padding(.bottom, 100)
                }
                .task { canAnimateEntrances = true }
                .transition(Self.gridTransition)
            }
        }
    }

    // Switching between shelf and grid: the old view clears quickly so the
    // two layouts are barely on screen together, then the new one settles
    // in with a single transform (no per-cover animation). The shelf slides
    // in from the right, the way the deck runs; the grid rises into place.
    private static let viewSwitchOut = Animation.easeIn(duration: 0.12)
    private static let viewSwitchIn = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42).delay(0.06)

    private static var shelfTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 56)).animation(viewSwitchIn),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .leading)).animation(viewSwitchOut)
        )
    }

    private static var gridTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 28)).animation(viewSwitchIn),
            removal: .opacity.animation(viewSwitchOut)
        )
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

    /// Title, then the section selector anchored beside it so it never
    /// moves; everything that changes per section sits on the right.
    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("Collection")
                .font(.system(size: 40, weight: .heavy))
                .tracking(-1.4)
                .foregroundStyle(Theme.textPrimary)
                .padding(.trailing, 6)

            FLPillToggle(
                selection: $contentMode,
                segments: [
                    .text(.albums, "Albums"),
                    .text(.artists, "Artists"),
                    .text(.tracks, "Tracks"),
                ]
            )

            Spacer(minLength: Theme.Spacing.lg)

            switch contentMode {
            case .albums:
                FLPillToggle(
                    selection: $albumViewStyle,
                    segments: [
                        .icon(.shelf, "books.vertical", help: "Shelf"),
                        .icon(.grid, "square.grid.2x2", help: "Grid"),
                    ]
                )
                FLSortMenu(
                    selection: $sortOption,
                    options: CollectionSortOption.allCases
                ) { $0.rawValue }
            case .artists:
                FLSortMenu(
                    selection: $artistSort,
                    options: ArtistSortOption.allCases
                ) { $0.rawValue }
            case .tracks:
                FLSortMenu(
                    selection: $tracksSortOption,
                    options: AllTracksSortOption.allCases
                ) { $0.rawValue }
                .onChange(of: tracksSortOption) { _, newValue in
                    // Each sort starts in its natural direction.
                    tracksAscending = newValue.defaultAscending
                }

                FLCircleIconButton(systemImage: tracksAscending ? "arrow.up" : "arrow.down") {
                    tracksAscending.toggle()
                }
                .help(directionHelp)
            }

            refreshButton
            SearchBarView(searchText: $searchText, style: .capsule)
        }
    }

    private var directionHelp: String {
        switch tracksSortOption {
        case .dateAdded: return tracksAscending ? "Oldest first" : "Newest first"
        case .fidelity: return tracksAscending ? "Lowest quality first" : "Best quality first"
        case .songName, .artistName: return tracksAscending ? "A to Z" : "Z to A"
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

    private func albumContextMenu(_ album: Album) -> [FLContextMenuItem] {
        LibraryMenus(player: player, library: library, playlistStore: playlistStore, playlistAdd: playlistAdd, router: router)
            .album(
                album,
                edit: { editingAlbum = album },
                remove: { removalRequest = LibraryRemovalRequest(title: album.name, tracks: album.tracks) }
            )
    }
}
