import SwiftUI

/// The library home / dashboard screen: the lyric hero, then a Recently Played
/// shelf, Your Listening (summary sentence, "On this day", hourly genre chart,
/// top artists), Top Albums This Week and the Fidelidex spec sheet. Monochrome
/// throughout. Sections that depend on listening history are hidden until that
/// history exists.
struct HomeView: View {
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
    @State private var isHeroHovering = false

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
            VStack(alignment: .leading, spacing: 34) {
                hero
                VStack(alignment: .leading, spacing: 56) {
                    recentlyPlayedSection
                    listeningSection
                    topAlbumsSection
                    FidelidexView(palette: highlight.palette)
                    homeFooter
                }
                .animation(.easeInOut(duration: 0.4), value: highlight.palette)
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 120)   // clear the floating player bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .removeFromLibraryConfirmation($removalRequest, library: library)
        .onAppear { recomputeMetrics() }
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
        .onChange(of: library.tracksRevision) { _, _ in recomputeMetrics() }
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(height: 56)
                .padding(.bottom, 28)
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Theme.textTertiary)

            if let pick = highlight.pick {
                Text("“\(pick.lyric)”")
                    .font(.system(size: 42, weight: .bold).italic())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                heroAttribution(pick).padding(.top, 16)
            } else {
                Text("Welcome to your library.")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if highlight.pick != nil { heroPinButton }
        }
        .onHover { isHeroHovering = $0 }
        // Banner lives behind the content so its height tracks the content
        // (which grows when the lyric wraps to two lines). The GeometryReader
        // pins the (otherwise greedy) blurred image to the content's size —
        // the negative padding bleeds it to the top/side edges.
        .background {
            GeometryReader { geo in
                heroBanner(size: geo.size)
            }
            .padding(.horizontal, -36)
            .padding(.top, -44)
            .padding(.bottom, -18)   // fall neatly into the gap below the attribution
            .allowsHitTesting(false)
        }
    }

    /// Discreet pin in the banner's top-right corner. Hidden until the hero is
    /// hovered; stays visible (accent-tinted) while pinned.
    private var heroPinButton: some View {
        Button { highlight.togglePin() } label: {
            Image(systemName: highlight.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13))
                .foregroundStyle(highlight.isPinned ? homeAccent : Theme.textTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(highlight.isPinned ? "Unpin lyric" : "Pin lyric")
        .opacity(highlight.isPinned || isHeroHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHeroHovering)
        .offset(y: -8)
    }

    /// Song credit shown under the lyric: `♪ Title — Artist`.
    private func heroAttribution(_ pick: HomeHighlight.Pick) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
            Text(pick.songTitle)
            if let artist = pick.artistDisplay {
                Text("—")
                Text(artist)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
    }

    /// Blurred artist image (or a generic gray blob) pushed to the right, with
    /// gradients fading it out toward the left so the headline stays readable.
    /// Bleeds past the page padding to the top/right edges. Only shown when a
    /// lyric has been picked.
    @ViewBuilder
    private func heroBanner(size: CGSize) -> some View {
        if let pick = highlight.pick {
            Group {
                // Decode through the downsampling cache instead of full-res
                // `NSImage(data:)`: under a 28pt blur + gradient mask a 640pt
                // source is visually indistinguishable, and vastly cheaper to
                // blur and composite while the page scrolls.
                if let data = pick.imageData, let nsImage = ArtworkImageCache.shared.thumbnail(
                    for: data,
                    id: ArtworkImageCache.contentID(for: data),
                    pointSize: 640,
                    scale: displayScale
                ) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 28)
                } else {
                    // Generic gray blob when no artist image is available.
                    RadialGradient(
                        colors: [Theme.surfaceElevated, .clear],
                        center: .init(x: 0.85, y: 0.4),
                        startRadius: 0,
                        endRadius: 320
                    )
                }
            }
            // Pin to the content-derived size so the (greedy) fill image can't
            // balloon the banner down the page.
            .frame(width: size.width, height: size.height, alignment: .trailing)
            .clipped()
            // Reveal the right side, with the image fading in further to the
            // left for a wider, smoother banner.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.10), location: 0.22),
                        .init(color: .black.opacity(0.5), location: 0.55),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            // Keep the left edge (wordmark/headline) firmly on the background.
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: Theme.background, location: 0.0),
                        .init(color: Theme.background.opacity(0.4), location: 0.35),
                        .init(color: Theme.background.opacity(0.0), location: 0.7),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
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
        let tracks = playlist.map { playlistStore.resolvedTracks(for: $0, in: library) } ?? []
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

    /// Custom context menu for an album tile/row on the home page — mirrors the
    /// Collection's album menu (playback, View Album, Add to Playlist, artist
    /// actions).
    private func albumContextMenu(_ album: Album) -> [FLContextMenuItem] {
        var items: [FLContextMenuItem] = [
            .button("Play Album", systemImage: "play.fill") {
                player.startFreshQueue(album.tracks, source: album.name)
                player.engine.play()
                listening.recordAlbumPlay(album)
            }
        ]
        items.append(contentsOf: playbackContextMenuItems(for: album.tracks, player: player))
        items.append(.divider)
        items.append(.button("View Album", systemImage: "square.grid.2x2") {
            router.navigateToAlbum(id: album.id)
        })
        items.append(addToPlaylistMenuItem(tracks: album.tracks))
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
        items.append(.divider)
        items.append(.button("Remove from Library", systemImage: "trash") {
            removalRequest = LibraryRemovalRequest(title: album.name, tracks: album.tracks)
        })
        return items
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

    /// "Add to Playlist" submenu for a set of tracks, matching the pattern used
    /// in AlbumDetailView / AllTracksView.
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
