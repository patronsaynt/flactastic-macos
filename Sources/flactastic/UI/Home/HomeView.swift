import SwiftUI

/// The library home: the day's lyric with its album's jewel case thrown in
/// beside it (`HomeTop`), then shelves built from the library and listening
/// history, streaming-service style (see `HomeSection` for the list and
/// `HomeFeed` for what fills them). Monochrome throughout, coloured only by
/// the palette sampled from the lyric's artist and audio-quality tiers. A section with
/// nothing to show is left out, so the page never has an empty block.
struct HomeView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(LibraryStore.self) private var library
    @Environment(DebugState.self) private var debugState
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
    /// The shelves' contents, rebuilt with the metrics.
    @State private var feed = HomeFeed()
    /// Mixes saved to the library this session, mix ID → playlist ID, so
    /// the menu opens the saved copy instead of saving another.
    @State private var savedMixes: [String: UUID] = [:]
    /// The "Playlist saved" notice, and the playlist it opens.
    @State private var savedNotice: (name: String, id: UUID)?
    @State private var noticeTask: Task<Void, Never>?
    @State private var removalRequest: LibraryRemovalRequest? = nil
    @State private var editingAlbum: Album? = nil
    /// Tracks of every playlist, resolved once per change to the playlists or
    /// the library. Resolving walks the whole library (and can migrate old
    /// entries), so it must not run inside a tile's body.
    @State private var playlistTracks: [UUID: [Track]] = [:]
    /// The lyric's song as the top shows it: its album, for the case, and where it's from.
    @State private var topSong: HomeTop.Song?
    @State private var hasEntered = false

    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }

    /// A brand-new library: loaded, and nothing in it yet. Home becomes a
    /// welcome with ways to add music instead of empty stats.
    private var isLibraryEmpty: Bool {
        debugState.emptyLibraryPreviewActive
            || (library.hasCompletedInitialLoad && library.tracks.isEmpty)
    }

    /// The lyric pick, unless Home is showing its empty-library welcome
    /// (a real empty library has no pick anyway; the debug preview hides it).
    private var shownPick: HomeHighlight.Pick? {
        isLibraryEmpty ? nil : highlight.pick
    }

    private func recomputeMetrics() {
        var m = HomeMetrics()
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
        m.topAlbums = listening.topAlbums(limit: 5, since: since)
        m.footerAlbumCount = library.albums.count
        m.footerHours = Int((library.tracks.compactMap(\.duration).reduce(0, +) / 3600).rounded())
        metrics = m
        recomputeChart()

        let stored = Self.storedRotation()
        let built = HomeFeed.build(.init(
            albums: library.albums, tracks: library.tracks, events: listening.events,
            recentContexts: listening.recentContexts, onThisDay: m.onThisDay,
            storedRotation: stored, resolver: library.makeArtistResolver(),
            isLibraryLoaded: library.hasCompletedInitialLoad
        ))
        if let rotation = built.rotation, rotation != stored { Self.store(rotation) }
        feed = built
    }

    private static let rotationKey = "flactastic.home.todayRotation"

    private static func storedRotation() -> TodayRotation? {
        UserDefaults.standard.data(forKey: rotationKey).flatMap { try? JSONDecoder().decode(TodayRotation.self, from: $0) }
    }

    private static func store(_ rotation: TodayRotation) {
        if let data = try? JSONEncoder().encode(rotation) { UserDefaults.standard.set(data, forKey: rotationKey) }
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
                top
                    .padding(.horizontal, 36)
                    .padding(.top, topBarInset + 4)
                VStack(alignment: .leading, spacing: 44) {
                    if isLibraryEmpty {
                        gettingStarted
                    } else {
                        ForEach(settings.homeSections) { section($0) }
                        homeFooter
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: highlight.palette)
                .padding(.horizontal, 36)
                .padding(.top, 24)
            }
            .padding(.bottom, 120)   // clear the floating player bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .bottom) { savedNoticeView }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: savedNotice?.id)
        .removeFromLibraryConfirmation($removalRequest, library: library)
        .onAppear {
            recomputeMetrics()
            topSong = resolveTopSong()
            playlistTracks = playlistStore.resolvedTracksForAll(in: library)
            withAnimation(calmMotion ? .easeOut(duration: 0.3) : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1)) {
                hasEntered = true
            }
        }
        .task(id: paletteSource.map(ArtworkImageCache.contentID(for:))) {
            // Home's colour comes from the artist's photo.
            highlight.updatePalette(from: paletteSource)
        }
        .onChange(of: listening.events.count) { _, _ in recomputeMetrics() }
        .onChange(of: highlight.pick) { _, _ in topSong = resolveTopSong() }
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
            // Plays don't change the top; only the pick and the library do.
            topSong = resolveTopSong()
            playlistTracks = playlistStore.resolvedTracksForAll(in: library)
        }
        // The day's picks are rolled (or found again) once the library has
        // finished loading.
        .onChange(of: library.hasCompletedInitialLoad) { _, _ in recomputeMetrics() }
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

    // MARK: - Top

    /// The wordmark and date, the day's lyric, and its album's jewel case
    /// in the air beside it (see `HomeTop`).
    private var top: some View {
        HomeTop(
            lyric: shownPick?.lyric,
            song: shownPick == nil ? nil : topSong,
            welcome: shownPick != nil ? nil : (isLibraryEmpty
                ? ("Welcome to FLACtastic.", "Your library is linked and ready. Add some music to hear it properly.")
                : ("Welcome to your library.", nil)),
            glow: highlight.palette?.accent,
            isPinned: highlight.isPinned,
            onPin: { highlight.togglePin() },
            calmMotion: calmMotion
        )
    }

    /// The artist's photo Home takes its colour from: their own profile
    /// picture first, then a fetched one, then their banner, then whatever
    /// image the lyric was picked with.
    private var paletteSource: Data? {
        guard let pick = shownPick else { return nil }
        // Pins saved before picks carried the artist resolve it from the name.
        let key = pick.artistKey
            ?? library.makeArtistResolver().keys(forCredit: pick.artistDisplay).first
        if let key {
            let override = artistStore.override(forKey: key)
            if let data = override?.profileImage ?? artistRemoteCache.entry(forKey: key)?.profileImage ?? override?.bannerImage {
                return data
            }
        }
        return pick.imageData
    }

    /// The lyric's song in the library: the album it's on, for the case,
    /// and "From Burning Out (2026)". Only a confident match: a same-titled
    /// song by someone else would put the wrong album in the air.
    private func resolveTopSong() -> HomeTop.Song? {
        guard let pick = highlight.pick else { return nil }
        let resolver = library.makeArtistResolver()
        let wanted = Set(resolver.keys(forCredit: pick.artistDisplay))
        let track = wanted.isEmpty ? nil : library.tracks.first { t in
            t.title == pick.songTitle
                && !wanted.isDisjoint(with: resolver.keys(forCredit: t.artist ?? t.albumArtist))
        }
        let album = track.flatMap(library.album(for:))
        return HomeTop.Song(
            title: pick.songTitle,
            artist: pick.artistDisplay,
            album: album,
            albumArtists: album.map { RackLayout.artists(of: $0, resolver: resolver) } ?? [],
            story: album.map { "From \($0.name)" + ($0.year.map { " (\($0))" } ?? "") }
        )
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

    // MARK: - Sections

    @ViewBuilder
    private func section(_ section: HomeSection) -> some View {
        switch section {
        case .recommended:
            recommendedSection
        case .recentlyPlayed:
            recentlyPlayedSection
        case .jumpBackIn:
            albumShelf("Jump back in", subtitle: "Old favourites you haven't played in a while", picks: feed.jumpBackIn)
        case .onRepeat:
            onRepeatSection
        case .mixes:
            mixesSection
        case .timeOfDay:
            albumShelf(feed.timeOfDayTitle, subtitle: feed.timeOfDaySubtitle, picks: feed.timeOfDay)
        case .recentlyAdded:
            albumShelf("Recently added", subtitle: "New in your library", picks: feed.recentlyAdded)
        case .listening:
            listeningSection
        case .bestSounding:
            bestSoundingSection
        case .fidelidex:
            FidelidexView(palette: highlight.palette)
        }
    }

    // MARK: Recommended for today

    @ViewBuilder
    private var recommendedSection: some View {
        if let today = feed.today {
            VStack(alignment: .leading, spacing: 14) {
                HomeSectionHeader(title: "Recommended for today", subtitle: "Picked fresh from your library")
                HomeTodayGrid(albums: today.albums) { width, height in
                    HomeTodayFeature(
                        album: today.lead, why: today.why, width: width, height: height,
                        onOpen: { router.navigateToAlbum(id: today.lead.id) },
                        onPlay: { playAlbum(today.lead) },
                        menu: { albumContextMenu(today.lead) }
                    )
                } tile: { album, size in
                    albumTile(album, caption: artistCaption(album), size: size)
                }
            }
        }
    }

    // MARK: Recently played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        let picks = feed.recent.filter { pick in
            switch pick.item.kind {
            case .album: albumsByID[pick.item.targetID] != nil
            case .playlist: UUID(uuidString: pick.item.targetID).flatMap { playlistsByID[$0] } != nil
            }
        }
        if !picks.isEmpty {
            HomeShelf(title: "Recently played", subtitle: "Albums and playlists you played last", items: picks) { pick in
                recentTile(pick)
            }
        }
    }

    @ViewBuilder
    private func recentTile(_ pick: HomeFeed.RecentPick) -> some View {
        switch pick.item.kind {
        case .album:
            if let album = albumsByID[pick.item.targetID] {
                let playing = isPlaying(album)
                albumTile(album, caption: artistCaption(album, note: playing ? "Now playing" : pick.when, accent: playing))
            }
        case .playlist:
            if let playlist = UUID(uuidString: pick.item.targetID).flatMap({ playlistsByID[$0] }) {
                let tracks = playlistTracks[playlist.id] ?? []
                HomeAlbumTile(
                    artwork: playlist.customArtwork ?? tracks.first?.artwork,
                    artworkID: nil,
                    title: playlist.name,
                    caption: Text("Playlist · \(pick.when)"),
                    onOpen: { router.navigateToPlaylist(id: playlist.id) },
                    onPlay: { playPlaylist(playlist, tracks: tracks) },
                    menu: { playlistContextMenu(playlist, tracks: tracks) }
                )
            }
        }
    }

    // MARK: Album shelves

    @ViewBuilder
    private func albumShelf(_ title: String, subtitle: String, picks: [HomeFeed.AlbumPick]) -> some View {
        if !picks.isEmpty {
            HomeShelf(title: title, subtitle: subtitle, items: picks) { pick in
                albumTile(pick.album, caption: artistCaption(pick.album, note: pick.note, accent: pick.noteIsAccent))
            }
        }
    }

    @ViewBuilder
    private var bestSoundingSection: some View {
        if !feed.bestSounding.isEmpty {
            HomeShelf(title: "Best sounding", subtitle: "Your highest-fidelity albums", items: feed.bestSounding) { pick in
                albumTile(pick.album, caption: artistCaption(pick.album, note: "\(pick.bits)-bit / \(Self.rateLabel(pick.rate))"),
                          badge: pick.quality)
            }
        }
    }

    // MARK: On repeat

    @ViewBuilder
    private var onRepeatSection: some View {
        let rows = feed.onRepeat
        if rows.count >= 3 {
            VStack(alignment: .leading, spacing: 14) {
                HomeSectionHeader(title: "On repeat", subtitle: "Your most-played tracks, last 30 days") {
                    Button("Play all") { play(rows.map(\.track), at: 0, source: "On repeat") }
                        .buttonStyle(QuietTextButtonStyle())
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HomeRepeatRow(
                            rank: index + 1, track: row.track, plays: row.plays, accent: homeAccent,
                            onPlay: { play(rows.map(\.track), at: index, source: "On repeat") },
                            menu: { playbackContextMenuItems(for: [row.track], player: player) }
                        )
                    }
                }
            }
        }
    }

    // MARK: Mixes

    @ViewBuilder
    private var mixesSection: some View {
        if !feed.mixes.isEmpty {
            let resolver = library.makeArtistResolver()
            HomeMixRow(title: "Mixes from your library", subtitle: "Built from your own files, fresh each day", mixes: feed.mixes) { mix, size in
                let photo = artistImage(credit: mix.leadArtist, resolver: resolver) ?? mix.tracks.first?.artwork
                HomeMixTile(
                    mix: mix,
                    image: photo,
                    size: size,
                    onPlay: { play(mix.tracks, at: 0, source: mix.name) },
                    menu: {
                        var items: [FLContextMenuItem] = [
                            .button("Play", systemImage: "play.fill") { play(mix.tracks, at: 0, source: mix.name) },
                            .button("Shuffle", systemImage: "shuffle") { play(mix.tracks, at: 0, source: mix.name, shuffle: true) },
                        ]
                        items += playbackContextMenuItems(for: mix.tracks, player: player)
                        items.append(.divider)
                        if let saved = savedMixes[mix.id], playlistsByID[saved] != nil {
                            items.append(.button("Open Saved Playlist", systemImage: "music.note.list") {
                                router.navigateToPlaylist(id: saved)
                            })
                        } else {
                            items.append(.button("Save Playlist to Library", systemImage: "plus.square.on.square") {
                                saveMix(mix, photo: photo)
                            })
                        }
                        return items
                    }
                )
            }
        }
    }

    /// Saves today's mix as a playlist in the library, with its cover
    /// rendered once to a 1024 × 1024 JPEG.
    private func saveMix(_ mix: HomeFeed.Mix, photo: Data?) {
        let playlist = playlistStore.createPlaylist(name: mix.name)
        playlistStore.addTracks(mix.tracks, to: playlist.id, relativeTo: library.rootURL)
        let date = Date.now.formatted(.dateTime.month(.wide).day().year())
        playlistStore.updatePlaylistMetadata(
            id: playlist.id,
            name: mix.name,
            description: "Saved from Home on \(date). With \(mix.artists.joined(separator: ", ")).",
            customArtwork: mix.coverJPEG(photo: photo)
        )
        // Only confirm once it's really there.
        guard playlistStore.playlists.contains(where: { $0.id == playlist.id }) else { return }
        savedMixes[mix.id] = playlist.id
        noticeTask?.cancel()
        savedNotice = (mix.name, playlist.id)
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            if !Task.isCancelled { savedNotice = nil }
        }
    }

    /// "Playlist saved", above the player bar. Clicking it opens the playlist.
    @ViewBuilder
    private var savedNoticeView: some View {
        if let notice = savedNotice {
            Button {
                savedNotice = nil
                router.navigateToPlaylist(id: notice.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                    (Text("Playlist saved").fontWeight(.semibold) + Text(" · \(notice.name)").foregroundColor(Theme.background.opacity(0.7)))
                        .lineLimit(1)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.textPrimary))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open \(notice.name)")
            .padding(.bottom, 104)   // above the floating player bar
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }

    /// An artist's picture: one set by hand first, then a fetched one.
    private func artistImage(credit: String, resolver: ArtistResolver) -> Data? {
        guard let key = resolver.keys(forCredit: credit).first else { return nil }
        if let override = artistStore.override(forKey: key), let data = override.profileImage ?? override.bannerImage {
            return data
        }
        return artistRemoteCache.entry(forKey: key)?.profileImage
    }

    // MARK: Your listening

    @ViewBuilder
    private var listeningSection: some View {
        // Gated on having any history: without plays there's nothing to show.
        if listening.hasHistory {
            VStack(alignment: .leading, spacing: 14) {
                HomeSectionHeader(title: "Your listening")
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 32) {
                        listeningFigures
                        Spacer(minLength: 16)
                        statsRangePicker
                    }
                    HStack(alignment: .top, spacing: 28) {
                        ListeningChart(
                            breakdown: chart,
                            palette: highlight.palette,
                            mode: $chartMode,
                            weekOffset: $chartWeekOffset,
                            canGoBack: chartCanGoBack
                        )
                        .frame(maxWidth: .infinity)
                        topArtistsColumn.frame(width: 240, alignment: .topLeading)
                        topAlbumsColumn.frame(width: 240, alignment: .topLeading)
                    }
                    .padding(.top, 20)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
                    .padding(.top, 22)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
            }
        }
    }

    /// Time listened, streak, and how much of it there was.
    private var listeningFigures: some View {
        let minutes = metrics.minutesListened
        let series = highlight.palette?.series(4)
        return HStack(alignment: .top, spacing: 32) {
            if minutes >= 60 {
                figure("\(minutes / 60)", unit: "h \(minutes % 60)m", label: "Listened, \(statsRange.label.lowercased())", color: homeAccent)
            } else {
                figure("\(minutes)", unit: "min", label: "Listened, \(statsRange.label.lowercased())", color: homeAccent)
            }
            if metrics.streakDays > 0 {
                figure("\(metrics.streakDays)", unit: metrics.streakDays == 1 ? "day" : "days", label: "Listening streak",
                       color: series?[1] ?? Theme.textPrimary)
            }
            figure(metrics.tracksPlayed.formatted(), unit: metrics.tracksPlayed == 1 ? "track" : "tracks",
                   label: "across \(metrics.albumsPlayed.formatted()) album\(metrics.albumsPlayed == 1 ? "" : "s")", color: Theme.textPrimary)
        }
    }

    private func figure(_ value: String, unit: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(value).foregroundColor(color)
             + Text(" " + unit).font(.system(size: 18, weight: .bold)).foregroundColor(Theme.textSecondary))
                .font(.system(size: 40, weight: .heavy))
                .tracking(-1)
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// Week / Month / Year / All time, side by side.
    private var statsRangePicker: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { range in
                let on = range == statsRange
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { statsRange = range }
                } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Theme.background : Theme.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(Capsule().fill(on ? Theme.textPrimary : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
    }

    private var topArtistsColumn: some View {
        let resolver = library.makeArtistResolver()
        return VStack(alignment: .leading, spacing: 4) {
            columnTitle("Top artists")
            if metrics.topArtists.isEmpty {
                Text("Not enough plays yet").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(metrics.topArtists.prefix(5).enumerated()), id: \.element.id) { index, artist in
                let key = resolver.keys(forCredit: artist.name).first
                let name = ArtistResolver.displayString(artist.name) ?? artist.name
                Button {
                    if let key { router.navigateToArtist(key: key) }
                } label: {
                    rankRow(index, image: artistImage(credit: artist.name, resolver: resolver), round: true,
                            name: name, value: minutesLabel(artist.minutes))
                }
                .buttonStyle(.plain)
                .disabled(key == nil)
                .help(key == nil ? "" : "Open \(name)")
                .flContextMenu { artistContextMenuItems(credit: artist.name, library: library, router: router) }
            }
        }
    }

    private var topAlbumsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            columnTitle("Top albums")
            if metrics.topAlbums.isEmpty {
                Text("Not enough plays yet").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(metrics.topAlbums.prefix(5).enumerated()), id: \.element.id) { index, rank in
                let album = albumsByID[rank.albumID]
                Button {
                    if let album { router.navigateToAlbum(id: album.id) }
                } label: {
                    rankRow(index, image: album?.artwork, imageID: album.map { "album:\($0.id)" }, round: false,
                            name: album?.name ?? rank.album, value: "\(rank.plays) play\(rank.plays == 1 ? "" : "s")")
                }
                .buttonStyle(.plain)
                .disabled(album == nil)
                .flContextMenu { album.map(albumContextMenu) ?? [] }
            }
        }
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.bottom, 6)
    }

    private func rankRow(_ index: Int, image: Data?, imageID: String? = nil, round: Bool, name: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(homeAccent)
                .frame(width: 16, alignment: .trailing)
            ArtworkView(data: image, size: 32, id: imageID, showsShadow: false)
                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: 42)
        .contentShape(Rectangle())
    }

    // MARK: Tiles and playback

    private func albumTile(_ album: Album, caption: Text, size: CGFloat = HomeTile.size, badge: AudioQuality? = nil) -> some View {
        HomeAlbumTile(
            artwork: album.artwork,
            artworkID: "album:\(album.id)",
            title: album.name,
            caption: caption,
            size: size,
            badge: badge,
            onOpen: { router.navigateToAlbum(id: album.id) },
            onPlay: { playAlbum(album) },
            menu: { albumContextMenu(album) }
        )
    }

    /// "Artist", or "Artist · note" with the note in the Home palette's colour when
    /// it's a highlight (how long since, now playing).
    private func artistCaption(_ album: Album, note: String? = nil, accent: Bool = false) -> Text {
        let artist = album.isMixCompilation ? "Mix Compilation" : (ArtistResolver.displayString(album.artist) ?? "Unknown Artist")
        guard let note else { return Text(artist) }
        let tail = accent ? Text(note).foregroundColor(homeAccent).fontWeight(.semibold) : Text(note)
        return Text(artist + " · ") + tail
    }

    private func isPlaying(_ album: Album) -> Bool {
        guard player.isPlaying, let current = player.currentTrack?.id else { return false }
        return album.tracks.contains { $0.id == current }
    }

    private func playAlbum(_ album: Album) {
        guard !album.tracks.isEmpty else { return }
        play(album.tracks, at: 0, source: album.name)
        listening.recordAlbumPlay(album)
    }

    private func playPlaylist(_ playlist: Playlist, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        play(tracks, at: 0, source: playlist.name)
        listening.recordPlaylistPlay(playlist)
    }

    private func play(_ tracks: [Track], at index: Int, source: String, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let start = shuffle ? Int.random(in: 0..<tracks.count) : index
        player.startFreshQueue(tracks, startAt: start, source: source)
        player.engine.play()
    }

    private static func rateLabel(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
    }

    /// The shared album menu (see `LibraryMenus`), with Play first.
    private func albumContextMenu(_ album: Album) -> [FLContextMenuItem] {
        let play: FLContextMenuItem = .button("Play Album", systemImage: "play.fill") { playAlbum(album) }
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
            .button("Play", systemImage: "play.fill") { playPlaylist(playlist, tracks: tracks) }
        ]
        items.append(contentsOf: playbackContextMenuItems(for: tracks, player: player))
        items.append(.divider)
        items.append(.button("View Playlist", systemImage: "music.note.list") {
            router.navigateToPlaylist(id: playlist.id)
        })
        return items
    }

    // MARK: - Helpers

    /// The Home palette's dominant color, or the monochrome accent when the artist's photo
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
/// seven days by day. Genres take the Home palette's colors (most listened =
/// dominant color), or gray shades when there's no palette, with a legend of
/// each genre's total. A quiet Day / Week switch sits in the header; in Week
/// mode, arrows step back through earlier weeks.
struct ListeningChart: View {
    let breakdown: GenreBreakdown
    /// Home palette colors for the genre series; gray shades when nil.
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

    /// Series color for a genre, most listened first: the Home palette when
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

    /// The side-by-side picker's label.
    var shortLabel: String {
        switch self {
        case .allTime: return "All time"
        case .year:    return "Year"
        case .month:   return "Month"
        case .week:    return "Week"
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

private extension View {
    /// Rising into place as Home first shows.
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
