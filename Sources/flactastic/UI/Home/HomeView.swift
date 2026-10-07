import SwiftUI

/// The library home / dashboard screen: the lyric hero, then a Recently Played
/// shelf, Your Listening (summary sentence, "On this day", hourly genre chart,
/// top artists), Top Albums This Week and the Fidelidex spec sheet. Monochrome
/// throughout. Sections that depend on listening history are hidden until that
/// history exists.
struct HomeView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(LibraryStore.self) private var library
    @Environment(ListeningStore.self) private var listening
    @Environment(PlayerState.self) private var player
    @Environment(NavigationRouter.self) private var router
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(HomeHighlight.self) private var highlight
    @Environment(ArtistStore.self) private var artistStore
    @Environment(ArtistRemoteCache.self) private var artistRemoteCache
    @Environment(LyricsRemoteCache.self) private var lyricsRemoteCache
    @Environment(\.metadataWriter) private var metadataWriter
    @Environment(\.displayScale) private var displayScale
    @Environment(Settings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ImportCoordinator.self) private var importCoordinator

    /// Time window for the listening-stats section. Persisted so the choice
    /// survives navigating away and back, and across launches.
    @AppStorage("flactastic.home.statsRange") private var statsRange: StatsRange = .week
    /// Day (hourly) or Week (daily) listening chart. Persisted alongside the range.
    @AppStorage("flactastic.home.chartMode") private var chartMode: ListeningChartMode = .day
    /// Weeks back from the current seven days in Week mode. Session-only, so
    /// the chart always reopens on the latest week.
    @State private var chartWeekOffset = 0
    @State private var chart = GenreBreakdown(series: [], buckets: [], starts: [])
    @State private var chartCanGoBack = false

    /// Album lookup by `Album.id`, so history items (which store only the album
    /// key) can resolve back to real albums for artwork and playback.
    /// Memoized on `LibraryStore` — building it here ran once per body eval.
    private var albumsByID: [String: Album] {
        library.albumsByID
    }

    /// Playlist lookup by UUID, so recent playlist entries resolve to artwork,
    /// tracks, and navigation targets. Memoized on `PlaylistStore`.
    private var playlistsByID: [UUID: Playlist] {
        playlistStore.playlistsByID
    }

    /// Everything on this page derived from listening history or whole-library
    /// scans, computed in one pass per *data* change. Each accessor does a
    /// full scan of `listening.events` (or all track durations), and this view
    /// re-renders whenever any observed store ticks — so computing them inline
    /// in section bodies made every Home render O(history).
    private struct HomeMetrics {
        var recentlyPlayed: [RecentItem] = []
        var onThisDay: OnThisDayPick? = nil
        var minutesListened: Int = 0
        var tracksPlayed: Int = 0
        var albumsPlayed: Int = 0
        var sessions: Int = 0
        var topGenre: (name: String, share: Double)? = nil
        var streakDays: Int = 0
        var topArtists: [RankedItem] = []
        var topAlbums: [AlbumRank] = []
        var footerAlbumCount: Int = 0
        var footerHours: Int = 0
    }
    @State private var metrics = HomeMetrics()
    @State private var removalRequest: LibraryRemovalRequest? = nil
    @State private var editingAlbum: Album? = nil
    /// Tracks of every playlist, resolved once per change to the playlists or
    /// the library. Resolving walks the whole library (and can migrate old
    /// entries), so it must not run inside a tile's body.
    @State private var playlistTracks: [UUID: [Track]] = [:]
    /// The banner image, blurred once off the main thread.
    @State private var bannerImage: NSImage?
    @State private var hasEntered = false

    /// Banner height below the top bar. The page's sections start this far
    /// down, less `bannerOverlap`, so Recently Played sits in the fade.
    private static let bannerHeight: CGFloat = 520
    private static let bannerOverlap: CGFloat = 116
    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }

    /// A brand-new library: loaded, and nothing in it yet. Home becomes a
    /// welcome with ways to add music instead of empty stats.
    private var isLibraryEmpty: Bool {
        library.hasCompletedInitialLoad && library.tracks.isEmpty
    }

    private func recomputeMetrics() {
        var m = HomeMetrics()
        m.recentlyPlayed = listening.recentlyPlayed(limit: 12)
        let albums = albumsByID
        m.onThisDay = listening.onThisDay { albums[$0] != nil }
        let since = statsRange.since()
        m.minutesListened = Int((listening.totalSecondsListened(since: since) / 60).rounded())
        m.tracksPlayed = listening.tracksPlayedCount(since: since)
        m.albumsPlayed = listening.albumsPlayedCount(since: since)
        m.sessions = listening.sessionCount(since: since)
        m.topGenre = listening.topGenre(since: since)
        m.streakDays = listening.currentStreakDays
        m.topArtists = listening.topArtists(limit: 5, since: since)
        m.topAlbums = listening.topAlbumsThisWeek(limit: 6)
        m.footerAlbumCount = library.albums.count
        m.footerHours = Int((library.tracks.compactMap(\.duration).reduce(0, +) / 3600).rounded())
        metrics = m
        recomputeChart()
    }

    /// The listening chart only: cheaper than a full recompute when just the
    /// chart mode or week changes.
    private func recomputeChart() {
        switch chartMode {
        case .day:
            chart = listening.hourlyGenreMinutes()
            chartCanGoBack = false
        case .week:
            let cal = Calendar.current
            let today = cal.startOfDay(for: .now)
            let lastDay = cal.date(byAdding: .day, value: -7 * chartWeekOffset, to: today) ?? today
            chart = listening.dailyGenreMinutes(endingOn: lastDay)
            if let first = listening.firstEventDate, let weekStart = chart.starts.first {
                chartCanGoBack = first < weekStart
            } else {
                chartCanGoBack = false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 56) {
                    if isLibraryEmpty {
                        gettingStarted
                    } else {
                        recentlyPlayedSection
                        listeningSection
                        topAlbumsSection
                        FidelidexView(palette: highlight.palette)
                        homeFooter
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: highlight.palette)
                .padding(.horizontal, 36)
                // Up into the banner's fade.
                .padding(.top, -Self.bannerOverlap)
            }
            .padding(.bottom, 120)   // clear the floating player bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .removeFromLibraryConfirmation($removalRequest, library: library)
        .onAppear {
            recomputeMetrics()
            playlistTracks = playlistStore.resolvedTracksForAll(in: library)
            withAnimation(calmMotion ? .easeOut(duration: 0.3) : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1)) {
                hasEntered = true
            }
        }
        .task(id: bannerSource.map(ArtworkImageCache.contentID(for:))) {
            // The colors come from exactly the image the banner shows.
            highlight.updatePalette(from: bannerSource)
            await loadBannerImage()
        }
        .onChange(of: listening.events.count) { _, _ in recomputeMetrics() }
        .onChange(of: listening.recentContexts) { _, _ in recomputeMetrics() }
        .onChange(of: statsRange) { _, range in
            // Longer windows than a week read better as days than as today's hours.
            if range != .week && chartMode == .day {
                chartMode = .week
            }
            recomputeMetrics()
        }
        .onChange(of: chartMode) { _, _ in recomputeChart() }
        .onChange(of: chartWeekOffset) { _, _ in
            withAnimation(.easeInOut(duration: 0.25)) { recomputeChart() }
        }
        .onChange(of: library.tracksRevision) { _, _ in
            recomputeMetrics()
            playlistTracks = playlistStore.resolvedTracksForAll(in: library)
        }
        .onChange(of: playlistStore.revision) { _, _ in
            playlistTracks = playlistStore.resolvedTracksForAll(in: library)
        }
        .sheet(item: $editingAlbum) { album in
            AlbumMetadataEditorView(album: album)
                .environment(library)
        }
        .task(id: library.hasCompletedInitialLoad) {
            guard library.hasCompletedInitialLoad else { return }
            await highlight.pickIfNeeded(
                library: library,
                lyricsCache: lyricsRemoteCache,
                artistStore: artistStore,
                artistRemoteCache: artistRemoteCache,
                metadataWriter: metadataWriter
            )
        }
    }

    // MARK: - Hero

    /// The banner: the artist image fills the width, runs up under the top
    /// bar, darkens toward the left for the words and melts into the page
    /// below, where Recently Played starts. The logo, date, lyric and song
    /// sit at its lower left; the pin follows the song.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            bannerBackdrop
            heroText
                .padding(.horizontal, 40)
                .padding(.bottom, Self.bannerOverlap + 34)
        }
        .frame(height: Self.bannerHeight + topBarInset)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(height: 44)
                .rise(hasEntered, calm: calmMotion, delay: 0.2)

            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 26)
                .rise(hasEntered, calm: calmMotion, delay: 0.45)

            if let pick = highlight.pick {
                Text("“\(pick.lyric)”")
                    .font(.system(size: 54, weight: .heavy).italic())
                    .tracking(-1.3)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: 980, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .rise(hasEntered, calm: calmMotion, delay: 0.2)
                heroAttribution(pick)
                    .padding(.top, 18)
                    .rise(hasEntered, calm: calmMotion, delay: 0.45)
            } else if isLibraryEmpty {
                Text("Welcome to FLACtastic.")
                    .font(.system(size: 54, weight: .heavy))
                    .tracking(-1.3)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 12)
                    .rise(hasEntered, calm: calmMotion, delay: 0.2)
                Text("Your library is linked and ready. Add some music to hear it properly.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 14)
                    .rise(hasEntered, calm: calmMotion, delay: 0.45)
            } else {
                Text("Welcome to your library.")
                    .font(.system(size: 54, weight: .heavy))
                    .tracking(-1.3)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 12)
                    .rise(hasEntered, calm: calmMotion, delay: 0.2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `♪ Title — Artist`, the artist a link to their page, then the pin.
    private func heroAttribution(_ pick: HomeHighlight.Pick) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(pick.songTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let artist = pick.artistDisplay {
                Text("—")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                ArtistLink(credit: artist, font: .system(size: 14), color: Theme.textSecondary)
            }
            heroPinButton
        }
        .lineLimit(1)
    }

    private var heroPinButton: some View {
        Button { highlight.togglePin() } label: {
            Image(systemName: highlight.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .foregroundStyle(highlight.isPinned ? homeAccent : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(HeroIconButtonStyle())
        .help(highlight.isPinned ? "Unpin lyric" : "Keep this lyric on Home")
        .accessibilityLabel(highlight.isPinned ? "Unpin lyric" : "Pin lyric")
    }

    /// The artist image (or a soft grey glow when there isn't one), settling
    /// from a slight zoom, under two washes: one darkening the left for the
    /// words, one fading the bottom into the page.
    private var bannerBackdrop: some View {
        Color.clear
            .overlay {
                Group {
                    if let bannerImage {
                        Image(nsImage: bannerImage)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .saturation(1.15)
                            .transition(.opacity)
                    } else {
                        RadialGradient(
                            colors: [Theme.surfaceElevated, .clear],
                            center: .init(x: 0.8, y: 0.4),
                            startRadius: 0,
                            endRadius: 520
                        )
                    }
                }
                .scaleEffect(hasEntered || calmMotion ? 1 : 1.1)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.6), value: hasEntered)
                .animation(.easeOut(duration: 0.4), value: bannerImage != nil)
            }
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Theme.background.opacity(0.8), location: 0),
                        .init(color: Theme.background.opacity(0.45), location: 0.42),
                        .init(color: Theme.background.opacity(0.05), location: 0.75),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Theme.background.opacity(colorScheme == .light ? 0.15 : 0.35), location: 0),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 0.46),
                        .init(color: Theme.background, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
    }

    /// The artist's banner, looked up live so one set after the pick (or
    /// after it was pinned) shows; otherwise the pick's own image, which is
    /// the banner, profile picture or album art it was made with.
    private var bannerSource: Data? {
        guard let pick = highlight.pick else { return nil }
        // Pins saved before picks carried the artist resolve it from the name.
        let key = pick.artistKey
            ?? library.makeArtistResolver().keys(forCredit: pick.artistDisplay).first
        if let key, let banner = artistStore.override(forKey: key)?.bannerImage {
            return banner
        }
        return pick.imageData
    }

    /// Blurs the banner once, off the main thread, into a small bitmap that's
    /// drawn scaled up: no live blur runs while the page scrolls, and the
    /// result is kept for the session, so coming back to Home is instant.
    private func loadBannerImage() async {
        guard let data = bannerSource, !data.isEmpty else {
            bannerImage = nil
            return
        }
        let maxPixel = 640
        let id = "home-banner:\(ArtworkImageCache.contentID(for: data))"
        if let cached = BlurredArtworkCache.shared.cached(id: id) {
            bannerImage = cached
            return
        }
        let box = await BlurredArtworkCache.shared.image(
            for: data,
            id: id,
            maxPixel: maxPixel,
            radius: PrerenderedImage.pixelRadius(points: 22, maxPixel: maxPixel)
        )
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.4)) { bannerImage = box.image }
    }

    // MARK: - Getting started

    /// Home for an empty library: the ways to bring music in, as cards.
    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Get started")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 18)],
                alignment: .leading,
                spacing: 18
            ) {
                StartCard(
                    icon: "square.stack",
                    title: "Import an album",
                    detail: "Copy an album's files into your library and tag them all at once."
                ) { importCoordinator.begin(.album) }
                StartCard(
                    icon: "music.note",
                    title: "Import a track",
                    detail: "Add a single song from anywhere on your Mac, checking its tags first."
                ) { importCoordinator.begin(.track) }
                if settings.showDownloadTab {
                    StartCard(
                        icon: "arrow.down.circle",
                        title: "Find music",
                        detail: "Search for albums and tracks in lossless quality."
                    ) { router.selectedTab = .download }
                }
                if let root = library.rootURL {
                    StartCard(
                        icon: "folder",
                        title: "Open library folder",
                        detail: "Drop music in yourself; FLACtastic picks it up."
                    ) { NSWorkspace.shared.open(root) }
                }
            }
            if library.rootURL != nil {
                Text("Added files outside the app? They show up on their own, or refresh with ⌘R.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .rise(hasEntered, calm: calmMotion, delay: 0.6)
    }

    private var homeFooter: some View {
        HStack(spacing: 6) {
            Text("\(metrics.footerAlbumCount.formatted()) albums")
            Text("·")
            Text("\(metrics.footerHours.formatted()) hours of music")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
    }

    // MARK: - Recently Played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        let items = metrics.recentlyPlayed
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader("Recently Played")
                    Spacer()
                    Text(recentCountLabel(items))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(items) { item in
                            recentTile(item)
                        }
                    }
                    // Room for the hover lift and its shadow.
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .padding(.horizontal, -2)
            }
        }
    }

    /// "12 albums", "3 playlists", or "12 albums & playlists".
    private func recentCountLabel(_ items: [RecentItem]) -> String {
        let albums = items.filter { $0.kind == .album }.count
        let playlists = items.count - albums
        if playlists == 0 { return "\(albums) album\(albums == 1 ? "" : "s")" }
        if albums == 0 { return "\(playlists) playlist\(playlists == 1 ? "" : "s")" }
        return "\(items.count) albums & playlists"
    }

    @ViewBuilder
    private func recentTile(_ item: RecentItem) -> some View {
        switch item.kind {
        case .album:   recentAlbumTile(item)
        case .playlist: recentPlaylistTile(item)
        }
    }

    /// Shared tile layout. `onOpen` is the default click action; `menu` supplies
    /// the right-click items.
    private func tile(
        artwork: Data?,
        artworkID: String?,
        title: String,
        subtitle: String,
        enabled: Bool,
        onOpen: @escaping () -> Void,
        menu: @escaping () -> [FLContextMenuItem]
    ) -> some View {
        Button(action: onOpen) {
            ShelfTile(artwork: artwork, artworkID: artworkID, title: title, subtitle: subtitle, size: 180)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .flContextMenu { menu() }
    }

    private func recentAlbumTile(_ item: RecentItem) -> some View {
        let album = albumsByID[item.targetID]
        let subtitle: String = {
            if album?.isMixCompilation == true { return "Mix Compilation" }
            return ArtistResolver.displayString(album?.artist)
                ?? ArtistResolver.displayString(item.subtitle)
                ?? item.subtitle
        }()
        return tile(
            artwork: album?.artwork,
            artworkID: album.map { "album:\($0.id)" },
            title: item.title,
            subtitle: subtitle,
            enabled: album != nil,
            onOpen: { if let album { router.navigateToAlbum(id: album.id) } },
            menu: { album.map(albumContextMenu) ?? [] }
        )
    }

    private func recentPlaylistTile(_ item: RecentItem) -> some View {
        let playlist = UUID(uuidString: item.targetID).flatMap { playlistsByID[$0] }
        let tracks = playlist.flatMap { playlistTracks[$0.id] } ?? []
        let artwork = playlist?.customArtwork ?? tracks.first?.artwork
        return tile(
            artwork: artwork,
            artworkID: nil,
            title: item.title,
            subtitle: item.subtitle,
            enabled: playlist != nil,
            onOpen: { if let playlist { router.navigateToPlaylist(id: playlist.id) } },
            menu: { playlist.map { playlistContextMenu($0, tracks: tracks) } ?? [] }
        )
    }

    /// The shared album menu (see `LibraryMenus`), with Play first.
    private func albumContextMenu(_ album: Album) -> [FLContextMenuItem] {
        let play: FLContextMenuItem = .button("Play Album", systemImage: "play.fill") {
            player.isShuffleEnabled = false
            player.startFreshQueue(album.tracks, source: album.name)
            player.engine.play()
            listening.recordAlbumPlay(album)
        }
        let menus = LibraryMenus(player: player, library: library, playlistStore: playlistStore, playlistAdd: playlistAddCoordinator, router: router)
        return [play] + menus.album(
            album,
            open: { router.navigateToAlbum(id: album.id) },
            edit: { editingAlbum = album },
            remove: { removalRequest = LibraryRemovalRequest(title: album.name, tracks: album.tracks) }
        )
    }

    /// Context menu for a playlist tile — "Play" first, then queue actions and
    /// View Playlist.
    private func playlistContextMenu(_ playlist: Playlist, tracks: [Track]) -> [FLContextMenuItem] {
        var items: [FLContextMenuItem] = [
            .button("Play", systemImage: "play.fill") {
                player.isShuffleEnabled = false
                player.startFreshQueue(tracks, source: playlist.name)
                player.engine.play()
                listening.recordPlaylistPlay(playlist)
            }
        ]
        items.append(contentsOf: playbackContextMenuItems(for: tracks, player: player))
        items.append(.divider)
        items.append(.button("View Playlist", systemImage: "music.note.list") {
            router.navigateToPlaylist(id: playlist.id)
        })
        return items
    }

    // MARK: - Your Listening

    @ViewBuilder
    private var listeningSection: some View {
        // The whole block is gated on having any history — without plays there
        // is nothing meaningful to show besides the always-available album count
        // already in the footer.
        if listening.hasHistory {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader("Your Listening")
                    Spacer()
                    statsRangePicker
                }
                HStack(alignment: .center, spacing: 40) {
                    listeningSentence
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let pick = metrics.onThisDay {
                        onThisDayPanel(pick)
                            .frame(width: 300, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 40) {
                    ListeningChart(
                        breakdown: chart,
                        palette: highlight.palette,
                        mode: $chartMode,
                        weekOffset: $chartWeekOffset,
                        canGoBack: chartCanGoBack
                    )
                        .frame(maxWidth: .infinity)
                    topArtistsColumn
                        .frame(width: 280, alignment: .topLeading)
                }
                .padding(.top, 22)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
            }
        }
    }

    /// Dropdown that switches the stats time window.
    private var statsRangePicker: some View {
        Menu {
            ForEach(StatsRange.allCases) { range in
                Button {
                    statsRange = range
                } label: {
                    if range == statsRange {
                        Label(range.label, systemImage: "checkmark")
                    } else {
                        Text(range.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(statsRange.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The stats as one sentence: "You've listened for 412 hours: 6.8k tracks
    /// across 318 albums in 1,204 sessions. Mostly Electronic (34% of plays),
    /// and you're on a 9-day streak." Figures are bright, connective text dim.
    private var listeningSentence: some View {
        var text = AttributedString()
        func dim(_ string: String) {
            var run = AttributedString(string)
            run.foregroundColor = Theme.textTertiary
            text += run
        }
        func figure(_ string: String, bold: Bool = false) {
            var run = AttributedString(string)
            run.foregroundColor = bold ? homeAccent : Theme.textPrimary
            if bold { run.font = .system(size: 28, weight: .bold) }
            text += run
        }
        func counted(_ n: Int, _ noun: String, compact: Bool = false) -> String {
            "\(compact ? n.abbreviated() : n.formatted()) \(noun)\(n == 1 ? "" : "s")"
        }

        let minutes = metrics.minutesListened
        let hours = Int((Double(minutes) / 60).rounded())
        dim(statsRange.sentenceLead)
        figure(hours >= 1 ? counted(hours, "hour") : counted(minutes, "minute"), bold: true)
        dim(": ")
        figure(counted(metrics.tracksPlayed, "track", compact: true))
        dim(" across ")
        figure(counted(metrics.albumsPlayed, "album"))
        dim(" in ")
        figure(counted(metrics.sessions, "session"))
        dim(".")

        let streak = metrics.streakDays
        if let genre = metrics.topGenre {
            dim(" Mostly ")
            figure(genre.name)
            dim(" (\(Int((genre.share * 100).rounded()))% of plays)")
            if streak > 0 {
                dim(", and you’re on a ")
                figure("\(streak)-day streak", bold: true)
            }
            dim(".")
        } else if streak > 0 {
            dim(" You’re on a ")
            figure("\(streak)-day streak", bold: true)
            dim(".")
        }

        return Text(text)
            .font(.system(size: 28, weight: .medium))
            .tracking(-0.28)
            .monospacedDigit()
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// An album resurfaced from this date in an earlier year. Only shown when
    /// `ListeningStore.onThisDay` finds one; otherwise the sentence takes the
    /// full width.
    private func onThisDayPanel(_ pick: OnThisDayPick) -> some View {
        let album = albumsByID[pick.albumID]
        let artist = ArtistResolver.displayString(album?.artist)
            ?? ArtistResolver.displayString(pick.artist)
            ?? pick.artist
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("On this day")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(pick.headline)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Button {
                if let album { router.navigateToAlbum(id: album.id) }
            } label: {
                HStack(spacing: 14) {
                    ArtworkView(data: album?.artwork, size: 88, id: album.map { "album:\($0.id)" })
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album?.name ?? pick.album)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Text("\(pick.plays) play\(pick.plays == 1 ? "" : "s") · \(pick.date.formatted(.dateTime.month(.wide).day().year()))")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(album == nil)
            .flContextMenu { album.map(albumContextMenu) ?? [] }
        }
        .padding(.leading, 28)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.divider).frame(width: 1)
        }
    }

    private var topArtistsColumn: some View {
        let artists = metrics.topArtists
        let maxMinutes = max(artists.first?.minutes ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Top Artists")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if artists.isEmpty {
                Text("Not enough plays yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(Array(artists.enumerated()), id: \.element.id) { idx, artist in
                    let key = library.makeArtistResolver().keys(forCredit: artist.name).first
                    Button {
                        if let key { router.navigateToArtist(key: key) }
                    } label: {
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                            .frame(width: 14, alignment: .trailing)
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Text(ArtistResolver.displayString(artist.name) ?? artist.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(idx == 0 ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(minutesLabel(artist.minutes))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .monospacedDigit()
                            }
                            ProgressBar(
                                fraction: artist.minutes / maxMinutes,
                                tint: idx == 0 ? homeAccent : Theme.textPrimary.opacity(0.45)
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(key == nil)
                    .help(key == nil ? "" : "Open \(ArtistResolver.displayString(artist.name) ?? artist.name)")
                    .flContextMenu {
                        artistContextMenuItems(credit: artist.name, library: library, router: router)
                    }
                }
            }
        }
    }

    // MARK: - Top Albums This Week

    @ViewBuilder
    private var topAlbumsSection: some View {
        let albums = metrics.topAlbums
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Top Albums This Week")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 32), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 2
                ) {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { idx, rank in
                        topAlbumRow(idx: idx, rank: rank)
                    }
                }
            }
        }
    }

    private func topAlbumRow(idx: Int, rank: AlbumRank) -> some View {
        let album = albumsByID[rank.albumID]
        let artist = ArtistResolver.displayString(album?.artist)
            ?? ArtistResolver.displayString(rank.artist)
            ?? rank.artist
        return Button {
            if let album { router.navigateToAlbum(id: album.id) }
        } label: {
            HStack(spacing: 14) {
                Text("\(idx + 1)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(idx == 0 ? homeAccent : Theme.textTertiary)
                    .monospacedDigit()
                    .frame(width: 22, alignment: .trailing)
                ArtworkView(data: album?.artwork, size: 44, id: album.map { "album:\($0.id)" })
                VStack(alignment: .leading, spacing: 3) {
                    Text(rank.album)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(rank.plays) plays")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                    Text("\(Int(rank.minutes.rounded())) min")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 10)
            .modifier(HoverRowBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .flContextMenu { album.map(albumContextMenu) ?? [] }
    }

    // MARK: - Helpers

    /// The banner's dominant color, or the monochrome accent when the banner
    /// has none to give.
    private var homeAccent: Color {
        highlight.palette?.accent ?? Theme.textPrimary
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .tracking(-0.2)
            .foregroundStyle(Theme.textPrimary)
    }
}

// MARK: - Shelf tile

/// A Recently Played tile: square artwork that lifts on hover, title and
/// subtitle beneath. Every tile is the same size.
private struct ShelfTile: View {
    let artwork: Data?
    let artworkID: String?
    let title: String
    let subtitle: String
    let size: CGFloat

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ArtworkView(data: artwork, size: size, id: artworkID)
                .shadow(
                    color: .black.opacity(isHovering ? 0.45 : 0.25),
                    radius: isHovering ? 14 : 3,
                    y: isHovering ? 10 : 2
                )
                .offset(y: isHovering ? -3 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isHovering = hovering }
        }
    }
}

/// Subtle surface fill behind a list row while the pointer is over it.
private struct HoverRowBackground: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Theme.surface : .clear)
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

// MARK: - Listening chart

/// Which view the Your Listening chart shows. Persisted via @AppStorage.
enum ListeningChartMode: String, CaseIterable {
    /// Today, one column per hour.
    case day
    /// Seven days, one column per day, browsable back week by week.
    case week

    var label: String {
        switch self {
        case .day:  return "Day"
        case .week: return "Week"
        }
    }
}

/// Screen Time–style chart of listening, stacked by genre: today by hour, or
/// seven days by day. Genres take the banner palette's colors (most listened =
/// dominant color), or gray shades when the banner has none, with a legend of
/// each genre's total. A quiet Day / Week switch sits in the header; in Week
/// mode, arrows step back through earlier weeks.
struct ListeningChart: View {
    let breakdown: GenreBreakdown
    /// Banner colors for the genre series; gray shades when nil.
    var palette: HomePalette? = nil
    @Binding var mode: ListeningChartMode
    /// 0 = the seven days ending today; 1 = the seven before that, and so on.
    @Binding var weekOffset: Int
    /// Whether there's listening history before the week on screen.
    let canGoBack: Bool

    private let plotHeight: CGFloat = 160
    private let axisWidth: CGFloat = 30
    private let axisGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: axisGap) {
                plot.frame(height: plotHeight)
                yAxis.frame(width: axisWidth, height: plotHeight)
            }
            xLabels
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, axisWidth + axisGap)

            if !breakdown.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: 16, alignment: .leading)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(Array(breakdown.series.enumerated()), id: \.offset) { idx, series in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(shade(idx))
                                    .frame(width: 9, height: 9)
                                Text(series.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Text(durationLabel(series.minutes))
                                .font(.system(size: 16, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.leading, 16)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(mode == .day ? "Listening by hour" : "Listening by day")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if mode == .day {
                Text("Today")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                weekNavigator
            }
            Spacer()
            modeSwitch
        }
    }

    /// "‹ Last 7 days ›" — steps back and forth a week at a time.
    private var weekNavigator: some View {
        HStack(spacing: 4) {
            navButton("chevron.left", help: "Previous week", enabled: canGoBack) {
                weekOffset += 1
            }
            Text(weekLabel)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .contentTransition(.numericText())
            navButton("chevron.right", help: "Next week", enabled: weekOffset > 0) {
                weekOffset = max(0, weekOffset - 1)
            }
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var weekLabel: String {
        guard weekOffset > 0, let first = breakdown.starts.first, let last = breakdown.starts.last else {
            return "Last 7 days"
        }
        return (first..<last.addingTimeInterval(1))
            .formatted(.interval.month(.abbreviated).day())
    }

    /// Quiet two-word switch: the active mode sits on a faint pill.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(ListeningChartMode.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { mode = option }
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: mode == option ? .medium : .regular))
                        .foregroundStyle(mode == option ? Theme.textPrimary : Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(mode == option ? Theme.surfaceElevated : .clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chart period")
    }

    // MARK: Plot

    /// Top of the y scale in minutes: an hour per hour column, or a round
    /// number of hours above the busiest day.
    private var scaleMinutes: Double {
        guard mode == .week else { return 60 }
        let peak = breakdown.buckets.map { $0.reduce(0, +) }.max() ?? 0
        for hours in [1.0, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24] where peak <= hours * 60 {
            return hours * 60
        }
        return 24 * 60
    }

    private var plot: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let count = max(breakdown.buckets.count, mode == .day ? 24 : 7)
            let colW = w / CGFloat(count)
            let barW = min(colW * 0.56, 40)
            ZStack(alignment: .bottomLeading) {
                // Top and midpoint gridlines.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0.5)); p.addLine(to: CGPoint(x: w, y: 0.5))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Theme.surfaceElevated, lineWidth: 1)
                // Dashed six-hour markers (Day mode only).
                if mode == .day {
                    Path { p in
                        for frac in [0.0, 0.25, 0.5, 0.75] {
                            let x = w * frac + 0.5
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        }
                    }
                    .stroke(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<count, id: \.self) { idx in
                        column(idx)
                            .frame(width: barW)
                            .frame(width: colW, height: h, alignment: .bottom)
                    }
                }

                Rectangle().fill(Theme.divider).frame(height: 1)

                if breakdown.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: w, height: h)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// One bucket's stack, most-listened genre at the base, rounded at the top.
    private func column(_ idx: Int) -> some View {
        let row = breakdown.buckets.indices.contains(idx) ? breakdown.buckets[idx] : []
        let total = row.reduce(0, +)
        let limit = scaleMinutes
        let scale = total > limit ? limit / total : 1
        let parts = row.indices.reversed().filter { row[$0] > 0 }
        return VStack(spacing: 1) {
            ForEach(Array(parts.enumerated()), id: \.element) { pos, series in
                UnevenRoundedRectangle(
                    topLeadingRadius: pos == 0 ? 3 : 0,
                    topTrailingRadius: pos == 0 ? 3 : 0
                )
                .fill(shade(series))
                .frame(height: max(1, row[series] * scale / limit * plotHeight - 1))
            }
        }
    }

    private var yAxis: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(axisLabel(scaleMinutes))
            Spacer()
            Text(axisLabel(scaleMinutes / 2))
            Spacer()
            Text("0")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -6)
    }

    @ViewBuilder
    private var xLabels: some View {
        if mode == .day {
            HStack(spacing: 0) {
                ForEach(["12 AM", "6 AM", "12 PM", "6 PM"], id: \.self) { label in
                    Text(label).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(breakdown.starts.enumerated()), id: \.offset) { idx, day in
                    let isToday = weekOffset == 0 && idx == breakdown.starts.count - 1
                    Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .day:  return "Nothing played yet today"
        case .week: return weekOffset == 0 ? "Nothing played in the last 7 days" : "Nothing played this week"
        }
    }

    private var accessibilitySummary: String {
        guard !breakdown.isEmpty else { return emptyMessage }
        let parts = breakdown.series.map { "\($0.name) \(durationLabel($0.minutes))" }
        let span = mode == .day ? "per hour today" : "per day, \(weekLabel)"
        return "Minutes listened \(span), by genre: " + parts.joined(separator: ", ")
    }

    /// Series color for a genre, most listened first: the banner palette when
    /// there is one, otherwise a gray ladder.
    private func shade(_ idx: Int) -> Color {
        let i = min(max(idx, 0), 3)
        if let palette { return palette.series(4)[i] }
        return Theme.textPrimary.opacity([1.0, 0.68, 0.42, 0.24][i])
    }

    /// "60m", "30m", "4h", "1.5h".
    private func axisLabel(_ minutes: Double) -> String {
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        let hours = minutes / 60
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    /// "2h 32m", "1h", "36m", or "<1m" for a sliver.
    private func durationLabel(_ minutes: Double) -> String {
        if minutes > 0 && minutes < 0.5 { return "<1m" }
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Stats time range

/// Time window for the home listening stats. Raw values persist via @AppStorage.
enum StatsRange: String, CaseIterable, Identifiable {
    case week, month, year, allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allTime: return "All time"
        case .year:    return "Past year"
        case .month:   return "Past month"
        case .week:    return "Past week"
        }
    }

    /// Opening words of the Your Listening sentence for this window.
    var sentenceLead: String {
        switch self {
        case .allTime: return "You’ve listened for "
        case .year:    return "This past year you’ve listened for "
        case .month:   return "This past month you’ve listened for "
        case .week:    return "This past week you’ve listened for "
        }
    }

    /// Lower-bound date for the window, or nil for all-time.
    func since(now: Date = .now) -> Date? {
        let cal = Calendar.current
        switch self {
        case .allTime: return nil
        case .year:    return cal.date(byAdding: .year, value: -1, to: now)
        case .month:   return cal.date(byAdding: .month, value: -1, to: now)
        case .week:    return cal.date(byAdding: .day, value: -7, to: now)
        }
    }
}

// MARK: - Number formatting

/// Compact minutes label: "0m", "47m", or "1.5h" for an hour or more.
func minutesLabel(_ minutes: Double) -> String {
    if minutes >= 60 {
        return String(format: "%.1fh", minutes / 60)
    }
    let m = Int(minutes.rounded())
    return "\(m)m"
}

private extension Int {
    /// Compact form for large counts ("12.4k"), plain otherwise.
    func abbreviated() -> String {
        if self >= 1000 {
            let thousands = Double(self) / 1000.0
            return String(format: "%.1fk", thousands)
        }
        return formatted()
    }
}

/// A quiet round icon button for the banner: a faint fill on hover, a
/// press scale.
private struct HeroIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeroIconButton(configuration: configuration)
    }

    private struct HeroIconButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering ? 0.1 : 0)))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

private extension View {
    /// The banner's words rising into place after the image settles.
    func rise(_ active: Bool, calm: Bool, delay: Double) -> some View {
        self
            .opacity(active ? 1 : 0)
            .offset(y: active || calm ? 0 : 20)
            .animation(calm ? .easeOut(duration: 0.3) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(delay), value: active)
    }
}

/// One way to add music on the empty Home: an icon, a title and a line on
/// what it does. Lifts a little on hover.
private struct StartCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.textPrimary.opacity(0.08)))
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 18)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isHovering ? Theme.surfaceElevated : Theme.surface)
            )
            .offset(y: isHovering ? -3 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}
