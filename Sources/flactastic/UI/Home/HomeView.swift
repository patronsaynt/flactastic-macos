import SwiftUI

/// The library home / dashboard screen. Section order mirrors the design with
/// one change: the fidelity panel ("Fidelidex") is moved to the bottom. Sections
/// that depend on listening history are hidden until that history exists.
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
    /// survives navigating away and back.
    @AppStorage("flactastic.home.statsRange") private var statsRange: StatsRange = .allTime

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
        var weeklyMinutes: [Double] = []
        var weeklyDayLabels: [String] = []
        var hoursListened: Int = 0
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

    private func recomputeMetrics() {
        var m = HomeMetrics()
        m.recentlyPlayed = listening.recentlyPlayed(limit: 12)
        m.weeklyMinutes = listening.weeklyMinutes()
        m.weeklyDayLabels = listening.weeklyDayLabels()
        let since = statsRange.since()
        m.hoursListened = Int((listening.totalSecondsListened(since: since) / 3600).rounded())
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
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                hero
                recentlyPlayedSection
                listeningStatsSection
                topAlbumsSection
                FidelidexView()
                homeFooter
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 120)   // clear the floating player bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear { recomputeMetrics() }
        .onChange(of: listening.events.count) { _, _ in recomputeMetrics() }
        .onChange(of: listening.recentContexts) { _, _ in recomputeMetrics() }
        .onChange(of: statsRange) { _, _ in recomputeMetrics() }
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
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Recently Played")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(items) { item in
                            recentTile(item)
                        }
                    }
                }
            }
        }
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
        title: String,
        subtitle: String,
        enabled: Bool,
        onOpen: @escaping () -> Void,
        menu: @escaping () -> [FLContextMenuItem]
    ) -> some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkView(data: artwork, size: 148)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: 148, alignment: .leading)
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

    // MARK: - Listening Stats

    @ViewBuilder
    private var listeningStatsSection: some View {
        // The whole block is gated on having any history — without plays there
        // is nothing meaningful to show besides the always-available album count
        // already in the hero.
        if listening.hasHistory {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    sectionHeader("Your Listening Stats")
                    Spacer()
                    statsRangePicker
                }
                statCards
                HStack(alignment: .top, spacing: 12) {
                    WeeklyListeningChart(
                        minutes: metrics.weeklyMinutes,
                        labels: metrics.weeklyDayLabels
                    )
                    topArtistsCard
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
            HStack(spacing: 4) {
                Text(statsRange.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statCards: some View {
        var cards: [HomeStatCard] = [
            HomeStatCard(icon: "clock", value: "\(metrics.hoursListened)h", label: "Hours Listened", accent: true),
            HomeStatCard(icon: "music.note", value: metrics.tracksPlayed.abbreviated(), label: "Tracks Played"),
            HomeStatCard(icon: "rectangle.stack", value: metrics.albumsPlayed.formatted(), label: "Albums"),
            HomeStatCard(icon: "headphones", value: metrics.sessions.formatted(), label: "Sessions"),
        ]
        if let genre = metrics.topGenre {
            cards.append(HomeStatCard(icon: "star", value: genre.name, label: "Top Genre",
                                      detail: "\(Int((genre.share * 100).rounded()))% of plays"))
        }
        let streak = metrics.streakDays
        cards.append(HomeStatCard(icon: "chart.line.uptrend.xyaxis",
                                  value: "\(streak) day\(streak == 1 ? "" : "s")",
                                  label: "Current Streak", accent: streak > 0))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            ForEach(cards) { $0 }
        }
    }

    private var topArtistsCard: some View {
        let artists = metrics.topArtists
        let maxMinutes = max(artists.first?.minutes ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Top Artists").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if artists.isEmpty {
                Text("Not enough plays yet").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { idx, artist in
                        HStack(spacing: 11) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                .monospacedDigit().frame(width: 12, alignment: .trailing)
                            VStack(spacing: 6) {
                                HStack {
                                    Text(ArtistResolver.displayString(artist.name) ?? artist.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(idx == 0 ? Theme.textPrimary : Theme.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(minutesLabel(artist.minutes))
                                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                                }
                                ProgressBar(
                                    fraction: artist.minutes / maxMinutes,
                                    tint: idx == 0 ? Theme.qualityLossless : Theme.textPrimary.opacity(0.45)
                                )
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 240, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.divider))
    }

    // MARK: - Top Albums This Week

    @ViewBuilder
    private var topAlbumsSection: some View {
        let albums = metrics.topAlbums
        if !albums.isEmpty {
            let maxMinutes = max(albums.first?.minutes ?? 1, 0.0001)
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Top Albums This Week")
                VStack(spacing: 10) {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { idx, rank in
                        topAlbumRow(idx: idx, rank: rank, maxMinutes: maxMinutes)
                    }
                }
            }
        }
    }

    private func topAlbumRow(idx: Int, rank: AlbumRank, maxMinutes: Double) -> some View {
        let album = albumsByID[rank.albumID]
        let artist = ArtistResolver.displayString(album?.artist)
            ?? ArtistResolver.displayString(rank.artist)
            ?? rank.artist
        return Button {
            if let album {
                player.startFreshQueue(album.tracks, source: album.name)
                player.engine.play()
                listening.recordAlbumPlay(album)
            }
        } label: {
            HStack(spacing: 14) {
                Text("\(idx + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(idx == 0 ? Theme.qualityLossless : Theme.textTertiary)
                    .monospacedDigit().frame(width: 16, alignment: .trailing)
                ArtworkView(data: album?.artwork, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rank.album).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(artist).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                ProgressBar(
                    fraction: rank.minutes / maxMinutes,
                    tint: idx == 0 ? Theme.qualityLossless : Theme.textPrimary.opacity(0.35)
                )
                .frame(width: 150)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(rank.plays) plays").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    Text("\(Int(rank.minutes.rounded())) min").font(.system(size: 10)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                }
                .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .flContextMenu { album.map(albumContextMenu) ?? [] }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Stat card

struct HomeStatCard: View, Identifiable {
    let id = UUID()
    let icon: String
    let value: String
    let label: String
    var detail: String? = nil
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(accent ? Theme.qualityLossless : Theme.textTertiary)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.divider))
                .padding(.bottom, 12)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 9)).tracking(1)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.divider))
    }
}

// MARK: - Weekly chart

struct WeeklyListeningChart: View {
    let minutes: [Double]
    let labels: [String]

    /// Fixed width reserved for the left-hand minutes axis so the day labels can
    /// be inset to line up with the plot.
    private let axisWidth: CGFloat = 32
    private let axisGap: CGFloat = 8

    var body: some View {
        let maxV = max(minutes.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weekly Listening").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Minutes per day").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text("This week").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            HStack(alignment: .top, spacing: axisGap) {
                yAxis(maxV).frame(width: axisWidth, height: 132)
                chart(maxV: maxV).frame(height: 132)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: axisWidth + axisGap)
                HStack {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                        Text(label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.divider))
    }

    /// Minutes scale: peak at the top, midpoint, and zero at the baseline.
    private func yAxis(_ maxV: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            axisLabel(maxV)
            Spacer()
            axisLabel(maxV / 2)
            Spacer()
            axisLabel(0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func axisLabel(_ value: Double) -> some View {
        Text(minutesLabel(value))
            .font(.system(size: 9))
            .foregroundStyle(Theme.textTertiary)
            .monospacedDigit()
    }

    private func chart(maxV: Double) -> some View {
        GeometryReader { geo in
            let pts = points(in: geo.size, maxValue: maxV)
            ZStack {
                // Horizontal gridlines aligned with the axis ticks.
                ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                    Rectangle()
                        .fill(Theme.divider.opacity(0.6))
                        .frame(height: 1)
                        .offset(y: geo.size.height * CGFloat(1 - frac) - geo.size.height / 2)
                }
                if pts.count > 1 {
                    // Filled area
                    areaPath(pts, height: geo.size.height)
                        .fill(LinearGradient(
                            colors: [Theme.qualityLossless.opacity(0.26), Theme.qualityLossless.opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                    // Line
                    linePath(pts)
                        .stroke(Theme.qualityLossless, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize, maxValue: Double) -> [CGPoint] {
        guard !minutes.isEmpty else { return [] }
        let stepX = minutes.count > 1 ? size.width / CGFloat(minutes.count - 1) : size.width
        return minutes.enumerated().map { idx, value in
            let x = CGFloat(idx) * stepX
            let y = size.height - CGFloat(value / maxValue) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = linePath(pts)
        p.addLine(to: CGPoint(x: pts.last!.x, y: height))
        p.addLine(to: CGPoint(x: pts.first!.x, y: height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Stats time range

/// Time window for the home listening stats. Raw values persist via @AppStorage.
enum StatsRange: String, CaseIterable, Identifiable {
    case allTime, year, month, week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allTime: return "All time"
        case .year:    return "Past year"
        case .month:   return "Past month"
        case .week:    return "Past week"
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
