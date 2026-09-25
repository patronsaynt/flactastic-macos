import SwiftUI
import AppKit

@main
struct FlactasticApp: App {
    // No default values here: every one of these is assigned in `init()`, and
    // a default would construct a full extra store that is immediately discarded.
    @State private var library: LibraryStore
    @State private var player: PlayerState
    @State private var listening: ListeningStore
    @State private var settings: Settings
    @State private var playlistStore: PlaylistStore
    @State private var artistStore: ArtistStore
    @State private var artistRemoteCache: ArtistRemoteCache
    @State private var artistImageFetcher: ArtistImageFetcher
    @State private var lyricsRemoteCache: LyricsRemoteCache
    @State private var lyricsFetcher: LyricsFetcher
    @State private var audioOutput: AudioOutputManager

    init() {
        // A write to a closed socket/pipe should surface as EPIPE, not kill the
        // app mid-album. Sockets also set SO_NOSIGPIPE; this is the backstop.
        signal(SIGPIPE, SIG_IGN)

        // Listening history recorder, injected into the player so plays are
        // tracked into whichever library is currently loaded. Settings is built
        // here too so the player can read the user's counted-play threshold.
        let settingsStore = Settings()
        _settings = State(initialValue: settingsStore)
        let listeningStore = ListeningStore()
        _listening = State(initialValue: listeningStore)
        let playerState = PlayerState(listening: listeningStore, settings: settingsStore)
        _player = State(initialValue: playerState)
        _audioOutput = State(initialValue: AudioOutputManager(settings: settingsStore, engine: playerState.engine))

        let store = ArtistStore()
        let cache = ArtistRemoteCache()
        _artistStore = State(initialValue: store)
        _artistRemoteCache = State(initialValue: cache)
        _artistImageFetcher = State(initialValue: ArtistImageFetcher(cache: cache, store: store))

        // Streaming downloads: a single Lucida provider backed by a hidden
        // WKWebView pointed at lucida.to. The WebView (and its WebKit content
        // process) is created lazily on first use — opening the Downloads tab
        // triggers `warmUp()`, which clears Cloudflare before the first
        // paste-and-resolve.
        let registry = StreamerRegistry()
        let lucidaController = LucidaWebController()
        // Shared across the provider (per-track fallback when Lucida's own
        // Spotify downloader fails) and the playlist rebuild pipeline
        // (Amazon-first source ordering) so both respect the same Odesli
        // rate-limit throttle instead of racing two independent ones.
        let amazonMatcher = AmazonMatchService()
        let lucidaProvider = LucidaWebProvider(controller: lucidaController, amazonMatcher: amazonMatcher)
        registry.register(lucidaProvider)
        _lucidaController = State(initialValue: lucidaController)
        let lib = LibraryStore()
        let writer = MetadataWriter()
        _streamerRegistry = State(initialValue: registry)
        let downloads = DownloadCoordinator(registry: registry, library: lib, writer: writer)
        _downloadCoordinator = State(initialValue: downloads)
        // Reuse the same library/writer instances above.
        _library = State(initialValue: lib)
        _metadataWriter = State(initialValue: writer)

        // Spotify-playlist rebuild: matches each track to Amazon Music via
        // Odesli, downloads through the shared coordinator, and assembles a
        // local playlist. Shares the playlistStore/library/Lucida instances.
        let plStore = PlaylistStore()
        _playlistStore = State(initialValue: plStore)
        _playlistRebuildCoordinator = State(initialValue: PlaylistRebuildCoordinator(
            downloads: downloads,
            playlistStore: plStore,
            library: lib,
            lucidaProvider: lucidaProvider,
            amazonMatcher: amazonMatcher
        ))

        let lyricsCache = LyricsRemoteCache()
        _lyricsRemoteCache = State(initialValue: lyricsCache)
        _lyricsFetcher = State(initialValue: LyricsFetcher(
            cache: lyricsCache,
            metadataWriter: writer
        ))
    }
    @State private var metadataWriter: MetadataWriter
    @State private var homeHighlight = HomeHighlight()
    @State private var importCoordinator = ImportCoordinator()
    @State private var playlistAddCoordinator = PlaylistAddCoordinator()
    @State private var router = NavigationRouter()
    @State private var spotifyAuth = SpotifyAuthController()
    @State private var discordPresence = DiscordPresenceService()
    @State private var streamerRegistry = StreamerRegistry()
    @State private var downloadCoordinator: DownloadCoordinator
    @State private var playlistRebuildCoordinator: PlaylistRebuildCoordinator
    @State private var lucidaController: LucidaWebController
    /// Backs the Debug tab in Settings (Debug Lucida / Debug Onboarding).
    @State private var debugState = DebugState()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        @Bindable var debugState = debugState
        WindowGroup {
            GeometryReader { geo in
                Group {
                    if settings.hasCompletedOnboarding {
                        ContentView()
                            .environment(library)
                            .environment(player)
                            .environment(listening)
                            .environment(settings)
                            .environment(audioOutput)
                            .environment(playlistStore)
                            .environment(artistStore)
                            .environment(artistRemoteCache)
                            .environment(artistImageFetcher)
                            .environment(lyricsRemoteCache)
                            .environment(lyricsFetcher)
                            .environment(importCoordinator)
                            .environment(playlistAddCoordinator)
                            .environment(router)
                            .environment(streamerRegistry)
                            .environment(downloadCoordinator)
                            .environment(playlistRebuildCoordinator)
                            .environment(spotifyAuth)
                            .environment(lucidaController)
                            .environment(\.debugMode, debugState.lucidaDebugEnabled)
                            .environment(\.metadataWriter, metadataWriter)
                            .environment(homeHighlight)
                            .environment(debugState)
                            .transition(.opacity)
                    } else {
                        OnboardingView()
                            .environment(library)
                            .environment(settings)
                            .environment(playlistStore)
                            .environment(listening)
                            .environment(spotifyAuth)
                            .transition(.opacity)
                    }
                }
                .frame(
                    width: max(1, geo.size.width / settings.uiScale),
                    height: max(1, geo.size.height / settings.uiScale)
                )
                .scaleEffect(settings.uiScale, anchor: .topLeading)
            }
            .sheet(isPresented: Binding(
                get: { lucidaController.needsUserChallenge },
                set: { _ in }
            )) {
                LucidaChallengeSheet()
                    .environment(lucidaController)
            }
            .preferredColorScheme(settings.useLightMode ? .light : .dark)
            // Onboarding gets a small window matching its card (see
            // OnboardingView/OnboardingDebugPreviewView's 640×720 viewport);
            // this only affects the window's *initial* size on a fresh
            // launch with no saved frame — real users only ever see
            // onboarding on that first run. Once `hasCompletedOnboarding`
            // flips, the floor jumps to the normal app minimum and the same
            // window grows to fit — no second window, no jump cut.
            .frame(
                minWidth: settings.hasCompletedOnboarding ? 1000 : 640,
                minHeight: settings.hasCompletedOnboarding ? 650 : 720
            )
            .background(Theme.background)
            .task { await bootstrap() }
            .onAppear {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSWindow.allowsAutomaticWindowTabbing = false
                installSpacebarMonitor()
                applyAppearance(useLight: settings.useLightMode)
            }
            .onChange(of: settings.useLightMode) { _, useLight in
                applyAppearance(useLight: useLight)
            }
            .background(DebugWindowController(enabled: $debugState.lucidaDebugEnabled))
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FLACtastic") { openWindow(id: "about") }
            }
            // Sync takes the (emptied) New Item slot at the top of the File
            // menu. It is a task with a beginning and an end rather than a
            // place in the library, so it opens a window instead of occupying
            // a permanent tab in the navigation.
            CommandGroup(replacing: .newItem) {
                Button("Sync…") { openWindow(id: "sync") }
            }
            CommandMenu("Collection") {
                Button("Refresh Collection") { library.refreshLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Import Track…") { importCoordinator.begin(.track) }
                Button("Import Album…") { importCoordinator.begin(.album) }
                Button("Import Files as Playlist…") { importCoordinator.begin(.playlist) }
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { player.engine.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { player.engine.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Volume Up") { player.engine.volumeUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Volume Down") { player.engine.volumeDown() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }

        // Library sync over the local network — opened from File → Sync…
        // The model is created by the view and torn down when the window
        // closes, so nothing advertises on the network unless this is open.
        Window("Sync", id: "sync") {
            SyncView()
                .environment(library)
                .environment(playlistStore)
                .preferredColorScheme(settings.useLightMode ? .light : .dark)
        }
        .windowResizability(.contentSize)

        // About FLACtastic — opened from the application menu.
        Window("About FLACtastic", id: "about") {
            AboutView()
                .preferredColorScheme(settings.useLightMode ? .light : .dark)
        }
        .windowResizability(.contentSize)

        // Auxiliary debug window for the Lucida WebKit bridge. Hidden by
        // default; toggled from Settings → Debug → "Debug Lucida".
        Window("Lucida Debug", id: "lucida-debug") {
            LucidaDebugView()
                .environment(lucidaController)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)

        // Standalone onboarding preview for developer testing. Reuses the
        // app's live stores via the environment (same precedent as the
        // Lucida debug window above), so it exercises the exact first-run
        // flow. Opened from Settings → Debug → "Debug Onboarding".
        Window("Onboarding Preview", id: "onboarding-debug") {
            OnboardingDebugPreviewView()
                .environment(library)
                .environment(settings)
                .environment(playlistStore)
                .environment(listening)
                .environment(spotifyAuth)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Menu bar mini-player. The `isInserted` binding reflects the Settings
        // toggle live (Settings is @Observable), so flipping the option in
        // Settings adds/removes the menu bar icon without needing a restart.
        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarPlayerView()
                .environment(library)
                .environment(player)
                .environment(settings)
                .environment(playlistStore)
                .environment(playlistAddCoordinator)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)
    }

    /// A `Binding<Bool>` over `settings.showMenuBarPlayer` for `MenuBarExtra`'s
    /// `isInserted` parameter. Built inline so we don't need `@Bindable` here.
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarPlayer && player.isPlaying },
            set: { _ in }
        )
    }

    /// Intercept the spacebar at the app level so it always triggers play/pause,
    /// even when a text field or other control has keyboard focus.
    private func installSpacebarMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [player] event in
            // Only bare space (no modifiers except shift which would be the same key)
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                      .subtracting(.capsLock) == [] else {
                return event
            }
            // Don't swallow space when a text field is editing
            if let responder = event.window?.firstResponder,
               responder is NSTextView {
                return event
            }
            // Step aside while the lyrics sync sheet is capturing beat taps.
            if player.isLyricsSyncActive {
                return event
            }
            player.engine.togglePlayPause()
            return nil // consume the event
        }
    }

    /// Force the app-wide NSAppearance so AppKit-backed surfaces (MenuBarExtra,
    /// Picker menus, NSColor dynamic providers) flip alongside SwiftUI's
    /// `.preferredColorScheme`.
    private func applyAppearance(useLight: Bool) {
        NSApplication.shared.appearance = NSAppearance(named: useLight ? .aqua : .darkAqua)
    }

    @MainActor
    private func bootstrap() async {
        // Async loads: file reads + JSON decodes run off the main actor so
        // launch doesn't block first paint on disk I/O (the listening log in
        // particular grows with use).
        await artistStore.loadAsync()
        await artistRemoteCache.loadAsync()
        await lyricsRemoteCache.loadAsync()
        player.engine.setVolume(settings.volume)
        // Route to the saved output device / format before anything plays,
        // so the choice never interrupts audio at launch.
        audioOutput.start()
        discordPresence.attach(player: player, settings: settings)
        // Network round-trips (profile + playlists) — never hold the library
        // scan, and with it the loading cover, behind them.
        Task { await spotifyAuth.restore() }
        if let path = settings.lastRootPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                library.openFolder(url)
                playlistStore.load(from: url)
                await listening.loadAsync(from: url)
                return
            }
        }
        // Nothing to scan — reveal the UI immediately so the empty state shows.
        library.hasCompletedInitialLoad = true
    }
}
