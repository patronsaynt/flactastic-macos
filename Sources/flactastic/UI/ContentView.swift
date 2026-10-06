import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(PlayerState.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(ImportCoordinator.self) private var importCoordinator
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(NavigationRouter.self) private var router
    @Environment(ArtistStore.self) private var artistStore
    @Environment(ArtistImageFetcher.self) private var artistImageFetcher
    @Environment(Settings.self) private var settings

    @State private var showSettings = false
    /// Mirrors the hosting window's fullscreen state. The custom top bar is
    /// the app's own view, not an `NSToolbar`, so hiding it for a fullscreen
    /// visualizer has to happen here in the layout.
    @State private var isFullScreen = false
    /// Set shortly after `hasCompletedInitialLoad` flips, once the loading
    /// cover's fade has played, to take it out of the hierarchy entirely.
    @State private var coverDismissed = false
    /// Drives the cover's fade-out, ahead of `coverDismissed` unmounting it.
    @State private var coverFading = false

    /// Longest the loading cover may stay up, however big the library is.
    /// Past this the UI is revealed while metadata keeps streaming in.
    private static let maxCoverDuration: Duration = .seconds(8)

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            if !hidesTopBar(router: router) {
                TopBarView(selectedTab: $router.selectedTab) {
                    showSettings = true
                }
            }

            mainContent(router: router)
        }
        .background(WindowFullScreenObserver(isFullScreen: $isFullScreen))
        // Extend into the title-bar region so the top bar shares the row with
        // the traffic lights (the NSWindow is configured for a full-size,
        // transparent title bar — see TitleBarConfigurator).
        .ignoresSafeArea(.container, edges: .top)
        .background(TitleBarConfigurator())
        .background(Theme.background)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: Binding(
            get: { importCoordinator.active },
            set: { if $0 == nil { importCoordinator.dismiss() } }
        )) { mode in
            switch mode {
            case .track:    ImportTrackView()
            case .album:    ImportAlbumView()
            case .playlist: ImportPlaylistView()
            }
        }
        .confirmationDialog(
            duplicateDialogTitle,
            isPresented: Binding(
                get: { playlistAddCoordinator.pending != nil },
                set: { if !$0 { playlistAddCoordinator.cancel() } }
            ),
            titleVisibility: .visible,
            presenting: playlistAddCoordinator.pending
        ) { pending in
            if pending.newCount > 0 {
                Button("Skip Duplicates (Add \(pending.newCount))") {
                    playlistAddCoordinator.resolveSkipDuplicates(store: playlistStore)
                }
            }
            Button("Add Anyway") {
                playlistAddCoordinator.resolveAddAll(store: playlistStore)
            }
            Button("Cancel", role: .cancel) {
                playlistAddCoordinator.cancel()
            }
        } message: { pending in
            Text(duplicateDialogMessage(for: pending))
        }
        .onChange(of: library.scanState) { _, newState in
            if case .done = newState {
                playlistStore.reconcile(with: library)
            }
        }
        .onChange(of: settings.showDownloadTab) { _, isShown in
            // The tab just disappeared from the bar out from under the user —
            // send them somewhere still visible instead of leaving them on a
            // now-unreachable screen.
            if !isShown && router.selectedTab == .download {
                router.selectedTab = .home
            }
        }
        .onChange(of: player.isPlaying) { oldValue, newValue in
            // Handle repeat only when playback stopped naturally (track reached the end),
            // not when the user manually pressed pause.
            if oldValue && !newValue && player.currentTrack != nil {
                let reachedEnd: Bool
                if let duration = player.duration, duration > 0 {
                    reachedEnd = player.currentTime >= duration - 0.5
                } else {
                    reachedEnd = false
                }
                if reachedEnd {
                    handleRepeat()
                }
            }
        }
    }

    /// Fullscreen is the only thing that takes the top bar away, and only for
    /// the visualizer — every other tab keeps its navigation at all times.
    private func hidesTopBar(router: NavigationRouter) -> Bool {
        isFullScreen && router.selectedTab == .visualizer
    }

    @ViewBuilder
    private func mainContent(router: NavigationRouter) -> some View {
        ZStack {
            Group {
                switch router.selectedTab {
                case .home:
                    HomeView()
                case .collection:
                    CollectionView()
                case .playlists:
                    PlaylistsTabView()
                case .download:
                    DownloadTabView()
                case .organizer:
                    OrganizerView()
                case .visualizer:
                    VisualizerView()
                }
            }
            .id(router.selectedTab)
            .transition(.opacity)

            // Opaque cover that hides the populating grid/list during the
            // initial library scan. Its visibility is local `@State` owned by
            // `runLoadingCover()`, not a direct read of the library flag, so
            // the cover can never outlive the load (or `maxCoverDuration`)
            // even if an observation update is missed.
            if !coverDismissed {
                LoadingCoverView()
                    .opacity(coverFading ? 0 : 1)
                    .allowsHitTesting(!coverFading)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: library.hasCompletedInitialLoad) { _, done in
            if done { prefetchArtistImages() }
        }
        .task { await runLoadingCover() }
        .task {
            if library.hasCompletedInitialLoad { prefetchArtistImages() }
        }
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .overlay(alignment: .bottomTrailing) {
            if player.isQueueVisible {
                QueuePanelView()
                    .frame(width: 340)
                    .padding(.top, Theme.Spacing.lg)
                    .padding(.trailing, Theme.Spacing.lg)
                    .padding(.bottom, 16)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if router.selectedTab != .visualizer && router.selectedTab != .download
                && !router.hidesPlayerBar {
                FloatingPlayerBar()
                    .frame(maxWidth: 700)
                    .padding(.bottom, 16)
                    .offset(x: player.isQueueVisible ? -180 : 0)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: router.hidesPlayerBar)
        .overlay {
            if let data = router.artworkZoomData {
                artworkZoomOverlay(data: data)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: player.isQueueVisible)
        .animation(.easeInOut(duration: 0.3), value: router.artworkZoomData != nil)
        .animation(.easeInOut(duration: 0.25), value: router.selectedTab)
        .background(Theme.background)
    }

    /// Holds the loading cover until the initial library load resolves or
    /// `maxCoverDuration` passes, then fades and unmounts it.
    ///
    /// Polls the flag instead of relying only on `.onChange`: observation of
    /// `hasCompletedInitialLoad` has been seen to be dropped at launch (SwiftUI
    /// re-rendered in the flag's `willSet`, read the old value, and never
    /// heard the change), which left the cover up until something else — like
    /// switching tabs — forced a redraw. The poll costs nothing measurable.
    private func runLoadingCover() async {
        let deadline = ContinuousClock.now + Self.maxCoverDuration
        while !library.hasCompletedInitialLoad && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        withAnimation(.easeOut(duration: 0.35)) { coverFading = true }
        // Outlast the fade, then unmount without animation.
        try? await Task.sleep(for: .milliseconds(400))
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { coverDismissed = true }
    }

    @ViewBuilder
    private func artworkZoomOverlay(data: Data) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                GeometryReader { geo in
                    let size = min(geo.size.width, geo.size.height) * 0.85
                    ArtworkView(data: data, size: size, fullResolution: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer()
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        router.artworkZoomData = nil
                    }
                }
                .buttonStyle(PillButtonStyle())
                .padding(.bottom, Theme.Spacing.xl)
                .background {
                    Button("") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            router.artworkZoomData = nil
                        }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
                }
            }
        }
    }

    /// Kick off a background pass over every artist in the library so their
    /// images are ready before the user opens the Artists tab. Cheap when
    /// the cache is already warm — `ensureImage` no-ops on hits.
    private func prefetchArtistImages() {
        guard settings.autoFetchArtistImages else { return }
        let resolver = library.makeArtistResolver()
        // Artists hidden from the lineup (feature-only, unless "Show All
        // Artists" is on) fetch their image when their page opens instead.
        let summaries = library.allArtists(resolver: resolver, overrides: artistStore.overrides)
            .filter { settings.showAllArtists || !$0.albums.isEmpty || !$0.singles.isEmpty }
        let artists = summaries.map { (key: $0.id, displayName: $0.displayName) }
        artistImageFetcher.prefetchAll(artists)
    }

    private var duplicateDialogTitle: String {
        guard let p = playlistAddCoordinator.pending else { return "" }
        return p.duplicateCount == p.totalCount
            ? "Already in Playlist"
            : "Duplicate Tracks"
    }

    private func duplicateDialogMessage(for p: PlaylistAddCoordinator.PendingAdd) -> String {
        if p.duplicateCount == p.totalCount {
            let noun = p.totalCount == 1 ? "track is" : "tracks are"
            return "All \(p.totalCount) \(noun) already in \"\(p.playlistName)\"."
        }
        let dupNoun = p.duplicateCount == 1 ? "track" : "tracks"
        return "\(p.duplicateCount) of \(p.totalCount) \(dupNoun) are already in \"\(p.playlistName)\"."
    }

    private func handleRepeat() {
        switch player.repeatMode {
        case .off:
            break
        case .one:
            player.engine.seek(to: 0)
            player.engine.play()
        case .all:
            let queue = player.queue
            if !queue.isEmpty {
                player.engine.setQueue(queue, startAt: 0)
                player.engine.play()
            }
        }
        // Note: we keep `engine.setQueue` here (not `startFreshQueue`) because
        // repeat-all replays the same queue, so user-queued markers must survive.
    }
}
