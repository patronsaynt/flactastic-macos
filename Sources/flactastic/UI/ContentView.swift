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
    @Environment(DebugState.self) private var debugState
    @Environment(LyricsFetcher.self) private var lyricsFetcher
    /// On Organizer, the player starts tucked away past the window edge.
    @State private var isPuckTucked = true
    @Environment(\.metadataWriter) private var metadataWriter

    /// Mirrors the hosting window's fullscreen state. The custom top bar is
    /// the app's own view, not an `NSToolbar`, so hiding it for a fullscreen
    /// visualizer has to happen here in the layout.
    @State private var isFullScreen = false
    /// Set shortly after `hasCompletedInitialLoad` flips, once the loading
    /// cover's fade has played, to take it out of the hierarchy entirely.
    @State private var coverDismissed = false
    /// Drives the cover's fade-out, ahead of `coverDismissed` unmounting it.
    @State private var coverFading = false
    /// The cover dips to black once loading is done, and holds there while
    /// the library finishes its launch work, before fading into the app.
    @State private var coverBlackout = false

    /// Longest the cover holds on black waiting for that launch work.
    private static let maxBlackoutHold: Duration = .seconds(3)

    /// Longest the loading cover may stay up, however big the library is.
    /// Past this the UI is revealed while metadata keeps streaming in.
    private static let maxCoverDuration: Duration = .seconds(8)

    var body: some View {
        @Bindable var router = router
        // The top bar floats over the page. Pages run to the top of the
        // window, under the bar, and keep their own titles and controls
        // `topBarInset` down.
        let inset = hidesTopBar(router: router) ? 0 : TopBarView.height
        mainContent(router: router)
            // UI for nerds' animation speed: every animation in the window
            // runs faster (above 1) or slower.
            .transaction { t in
                let speed = UIStyle.shared.animationSpeed
                if speed != 1, let animation = t.animation { t.animation = animation.speed(speed) }
            }
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.topBarInset, inset)
            // Each tab's one-time tips, over the page but under the top bar
            // so the tabs stay reachable.
            .overlay { if isChromeRevealed { TabTutorialOverlay() } }
            .overlay(alignment: .top) {
                if isChromeRevealed && !hidesTopBar(router: router) {
                    TopBarView(selectedTab: $router.selectedTab)
                        .transition(.opacity)
                }
            }
            // The queue runs the full height of the window, over the top bar's
            // trailing end, with a pull tab on the edge while it's closed.
            .overlay(alignment: .trailing) {
                if player.isQueueVisible {
                    QueuePanelView()
                        .transition(.move(edge: .trailing))
                } else if isChromeRevealed && player.currentTrack != nil && router.selectedTab != .visualizer {
                    QueuePullTab(count: max(0, player.queue.count - player.currentIndex - 1)) {
                        withAnimation(QueuePanelView.motion) { player.isQueueVisible = true }
                    }
                    .transition(.opacity)
                }
            }
            .animation(QueuePanelView.motion, value: player.isQueueVisible)
            .overlay(alignment: .bottomLeading) {
                if debugState.performanceOverlayActive {
                    PerformanceOverlay().padding(16)
                }
            }
        .background(WindowFullScreenObserver(isFullScreen: $isFullScreen))
        // Extend into the title-bar region so the top bar shares the row with
        // the traffic lights (the NSWindow is configured for a full-size,
        // transparent title bar — see TitleBarConfigurator).
        .ignoresSafeArea(.container, edges: .top)
        .background(TitleBarConfigurator(showsWindowButtons: isChromeRevealed))
        .background(Theme.background)
        .sheet(isPresented: $router.showSettings) {
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

    /// The window's chrome (traffic lights, top bar, player bar, queue tab,
    /// tips) waits behind the loading cover and comes in as it fades, each
    /// with its own entrance, in the cover fade's transaction.
    private var isChromeRevealed: Bool { coverFading || coverDismissed || !UIStyle.shared.launchFade }

    private func showsPlayerBar(router: NavigationRouter) -> Bool {
        isChromeRevealed && router.selectedTab != .visualizer && router.selectedTab != .download && !router.hidesPlayerBar
            // The Playlists page docks its own mini player under its list.
            && !(router.selectedTab == .playlists && router.playlistsPath.isEmpty)
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
                    .overlay(Color.black.opacity(coverBlackout ? 1 : 0).ignoresSafeArea())
                    .opacity(coverFading ? 0 : 1)
                    .allowsHitTesting(!coverFading)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: library.hasCompletedInitialLoad) { _, done in
            if done { prefetchArtistImages() }
            GenreScanner.shared.libraryChanged()
        }
        // Genres: new tracks count as imports; a playing untagged track is
        // looked up (with the next two), like lyrics.
        .onAppear {
            GenreScanner.shared.attach(library: library, writer: metadataWriter, lyrics: lyricsFetcher, settings: settings)
        }
        .onChange(of: library.tracksRevision) { _, _ in GenreScanner.shared.libraryChanged() }
        .task(id: player.currentTrack?.id) {
            let queue = player.engine.queue
            let next = queue.indices.contains(player.engine.currentIndex + 1)
                ? Array(queue[(player.engine.currentIndex + 1)...].prefix(2)) : []
            GenreScanner.shared.trackStarted(player.currentTrack, upcoming: next)
        }
        .overlay(alignment: .bottom) { GenreStatusPill().padding(.bottom, router.playerBarClearance + 16) }
        .task { await runLoadingCover() }
        .task {
            if library.hasCompletedInitialLoad { prefetchArtistImages() }
        }
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .overlay(alignment: .bottom) {
            if showsPlayerBar(router: router) {
                // The corner puck, bottom-right (or bottom-left, by UI for
                // nerds); on the right, while the queue is open it slides left
                // to sit beside the panel. It opens toward the middle into the
                // full bar. Concrete numbers so the moves animate.
                GeometryReader { geo in
                    let margin = Theme.Spacing.lg
                    let side = UIStyle.shared.playerSide
                    let open = player.isQueueVisible
                    let queue = open ? QueuePanelView.width : 0
                    // On Organizer the player can tuck away past the window
                    // edge (its Organize button sits where the puck does),
                    // leaving a handle at that edge to bring it back.
                    let tuckable = router.selectedTab == .organizer
                    let tucked = tuckable && isPuckTucked
                    let edge = margin + (tuckable ? PuckTuckHandle.width : 0)
                    let room = geo.size.width - edge * 2 - queue
                    let away = (side == .right ? 1.0 : -1.0) * (max(room, CornerPlayerPuck.collapsedWidth) + edge + 24)
                    CornerPlayerPuck(expandedWidth: max(0, min(UIStyle.shared.playerBarWidth, room)))
                        .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { shown in
                            // Clear only the puck, not the bar it opens into.
                            // Empty (nothing playing) measures 0: no clearance.
                            router.playerBarClearance = shown && !tucked ? CornerPlayerPuck.collapsedHeight + 16 : 0
                        }
                        .onChange(of: tucked) { _, now in
                            router.playerBarClearance = now ? 0 : CornerPlayerPuck.collapsedHeight + 16
                        }
                        .onDisappear { router.playerBarClearance = 0 }
                        .padding(.leading, side == .left ? edge : 0)
                        .padding(.trailing, side == .right ? edge + queue : 0)
                        .padding(.bottom, 16)
                        .offset(x: tucked ? away : 0)
                        .opacity(tucked ? 0 : 1)
                        .allowsHitTesting(!tucked)
                        .accessibilityHidden(tucked)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.bottomCorner)
                        .animation(PuckTuckHandle.motion, value: tucked)
                    if tuckable {
                        PuckTuckHandle(side: side, isTucked: isPuckTucked) {
                            withAnimation(PuckTuckHandle.motion) { isPuckTucked.toggle() }
                        }
                        .padding(.trailing, side == .right ? queue : 0)
                        // Level with the puck's middle.
                        .padding(.bottom, 16 + (CornerPlayerPuck.collapsedHeight - PuckTuckHandle.height) / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.bottomCorner)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: router.selectedTab == .organizer)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: UIStyle.shared.playerSide)
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
        .animation(QueuePanelView.motion, value: player.isQueueVisible)
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
        if library.hasCompletedInitialLoad {
            // Dip to black, and hold there while the library runs its
            // whole-library launch passes on the main thread. Revealing the app
            // during them made the first thing on screen — Home's thrown case —
            // stutter and hang; behind black they cost nothing visible.
            Perf.event("Cover blackout")
            withAnimation(.easeInOut(duration: 0.3)) { coverBlackout = true }
            try? await Task.sleep(for: .milliseconds(300))
            let hold = ContinuousClock.now + Self.maxBlackoutHold
            while !library.hasFinishedLaunchWork && ContinuousClock.now < hold {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            // A beat for SwiftUI to commit the re-render that work caused.
            try? await Task.sleep(for: .milliseconds(150))
        }
        Perf.event("Cover fade")
        withAnimation(.easeOut(duration: 0.5)) { coverFading = true }
        // Outlast the fade, then unmount without animation.
        try? await Task.sleep(for: .milliseconds(550))
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { coverDismissed = true }
        router.isLaunchRevealed = true
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
