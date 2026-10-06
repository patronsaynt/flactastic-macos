import SwiftUI

/// The Artists section of the Collection tab: a festival-poster lineup.
/// Names flow together, sized by how many albums and singles each artist
/// has, so headliners read first. Hovering a name shows the artist in the
/// side panel; clicking opens their page.
struct ArtistsCollectionView: View {
    let searchText: String
    let sort: ArtistSortOption

    @Environment(LibraryStore.self)        private var library
    @Environment(ArtistStore.self)         private var artistStore
    @Environment(ArtistRemoteCache.self)   private var artistRemoteCache
    @Environment(ArtistImageFetcher.self)  private var artistImageFetcher
    @Environment(PlayerState.self)         private var player
    @Environment(Settings.self)            private var settings
    @Environment(NavigationRouter.self)    private var router
    @Environment(ListeningStore.self)      private var listening

    /// Cached full artist index. Building it walks every album and track, so
    /// it must NOT live in a computed property read from `body`: hovering
    /// names and remote image fetches mutate observable state constantly,
    /// and each mutation would rebuild the whole index. It's recomputed only
    /// when the library or artist overrides change.
    @State private var allSummaries: [ArtistSummary] = []
    @State private var featuredID: String?
    /// Plays per artist key, built only while sorting by Most Listens.
    @State private var listens: [String: ListenTally] = [:]

    struct ListenTally {
        var plays = 0
        var seconds: Double = 0
    }

    /// The grid normally lists only artists with releases of their own;
    /// feature-only artists join with "Show All Artists", and a search
    /// always finds them so they're never unreachable.
    private var summaries: [ArtistSummary] {
        let visible: [ArtistSummary]
        if searchText.isEmpty {
            visible = settings.showAllArtists
                ? allSummaries
                : allSummaries.filter { !$0.albums.isEmpty || !$0.singles.isEmpty }
        } else {
            let q = searchText.lowercased()
            visible = allSummaries.filter { $0.displayName.lowercased().contains(q) }
        }
        switch sort {
        case .name:
            return visible
        case .mostListens:
            return visible.sorted { a, b in
                let la = listens[a.id] ?? ListenTally(), lb = listens[b.id] ?? ListenTally()
                if la.plays != lb.plays { return la.plays > lb.plays }
                if la.seconds != lb.seconds { return la.seconds > lb.seconds }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        case .mostReleases:
            return visible.sorted { a, b in
                let ra = Self.releases(a), rb = Self.releases(b)
                if ra != rb { return ra > rb }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }

    private static func releases(_ s: ArtistSummary) -> Int { s.albums.count + s.singles.count }

    private func rebuildSummaries() {
        allSummaries = library.cachedAllArtists(
            overrides: artistStore.overrides,
            overridesRevision: artistStore.revision
        )
    }

    /// Credits each play to every artist on the track, the same way the
    /// artist pages resolve collaborations.
    private func rebuildListens() {
        guard sort == .mostListens else { return }
        let resolver = library.makeArtistResolver()
        var keysByCredit: [String: [String]] = [:]
        var tallies: [String: ListenTally] = [:]
        for event in listening.events {
            guard let credit = event.artist, !credit.isEmpty else { continue }
            let keys = keysByCredit[credit] ?? {
                let resolved = resolver.keys(forCredit: credit)
                keysByCredit[credit] = resolved
                return resolved
            }()
            for key in keys {
                if event.counted { tallies[key, default: ListenTally()].plays += 1 }
                tallies[key, default: ListenTally()].seconds += event.secondsListened
            }
        }
        listens = tallies
    }

    var body: some View {
        let list = summaries
        let featured = list.first { $0.id == featuredID } ?? list.first
        let listenSizes = sort == .mostListens ? listenNameSizes(for: list) : nil

        HStack(alignment: .top, spacing: 48) {
            ScrollView {
                if list.isEmpty {
                    Text(searchText.isEmpty ? "No artists in your library" : "No artists match your search")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 24)
                } else {
                    LineupLayout(spacing: 22, lineSpacing: 6) {
                        ForEach(list) { summary in
                            LineupName(
                                summary: summary,
                                size: listenSizes?[summary.id] ?? Self.nameSize(for: summary),
                                isFeatured: summary.id == featured?.id
                            ) {
                                router.collectionPath.append(NavigationRoute.artist(key: summary.id))
                            } onHover: {
                                featuredID = summary.id
                            }
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 100)
                }
            }
            .scrollIndicators(.automatic)

            if let featured {
                ArtistLineupPanel(
                    summary: featured,
                    portrait: preferredImage(for: featured),
                    plays: sort == .mostListens ? (listens[featured.id]?.plays ?? 0) : nil,
                    play: { play(featured) },
                    open: { router.collectionPath.append(NavigationRoute.artist(key: featured.id)) }
                )
                .frame(width: 300)
                .padding(.top, 20)
                .task(id: featured.id) {
                    if settings.autoFetchArtistImages {
                        artistImageFetcher.ensureImage(forKey: featured.id, displayName: featured.displayName)
                    }
                }
            }
        }
        .padding(.horizontal, collectionGutter)
        // Before the first frame, so the section never flashes empty while
        // it fades in. Usually a cache hit.
        .onAppear {
            rebuildSummaries()
            rebuildListens()
        }
        .onChange(of: sort) { rebuildListens() }
        .onChange(of: listening.events.count) { rebuildListens() }
        .onChange(of: library.tracksRevision) {
            rebuildSummaries()
            rebuildListens()
        }
        .onChange(of: artistStore.revision) { rebuildSummaries() }
    }

    /// Headliners, then the undercard, then everyone else.
    /// Under Most Listens, the bill follows plays instead: the most played
    /// tenth headline, the next quarter make the undercard, and anyone
    /// never played stays small. By rank rather than fixed play counts, so
    /// the poster keeps its shape however much history there is. `list` is
    /// already in play order.
    private func listenNameSizes(for list: [ArtistSummary]) -> [String: CGFloat] {
        let headliners = max(1, Int((Double(list.count) * 0.1).rounded()))
        let undercard = max(headliners, Int((Double(list.count) * 0.35).rounded()))
        var sizes: [String: CGFloat] = [:]
        sizes.reserveCapacity(list.count)
        for (rank, summary) in list.enumerated() {
            let plays = listens[summary.id]?.plays ?? 0
            sizes[summary.id] = plays == 0 ? 32 : rank < headliners ? 72 : rank < undercard ? 50 : 32
        }
        return sizes
    }

    private static func nameSize(for summary: ArtistSummary) -> CGFloat {
        switch releases(summary) {
        case 5...: return 72
        case 2...: return 50
        default: return 32
        }
    }

    private func preferredImage(for summary: ArtistSummary) -> Data? {
        if let override = artistStore.override(forKey: summary.id),
           let data = override.profileImage ?? override.bannerImage {
            return data
        }
        return artistRemoteCache.entry(forKey: summary.id)?.profileImage ?? summary.artworkSample
    }

    private func play(_ summary: ArtistSummary) {
        let tracks = (summary.albums + summary.singles + summary.appearsOn).flatMap(\.tracks)
        guard !tracks.isEmpty else { return }
        player.isShuffleEnabled = false
        player.startFreshQueue(tracks, startAt: 0, source: summary.displayName)
        player.engine.play()
    }
}

// MARK: - Lineup name

private struct LineupName: View {
    let summary: ArtistSummary
    let size: CGFloat
    let isFeatured: Bool
    let open: () -> Void
    let onHover: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 22) {
            Button(action: open) {
                Text(summary.displayName)
                    .font(.system(size: size, weight: .heavy))
                    .tracking(-size * 0.035)
                    .foregroundStyle(isFeatured || isHovering ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                    .animation(.easeOut(duration: 0.2), value: isFeatured || isHovering)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                isHovering = inside
                if inside { onHover() }
            }
            .help("Open \(summary.displayName)")

            // The dot between names.
            Circle()
                .fill(Theme.divider)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Side panel

/// The hovered artist: portrait, counts and quick actions.
private struct ArtistLineupPanel: View {
    let summary: ArtistSummary
    let portrait: Data?
    /// Shown while the lineup is sorted by listens.
    let plays: Int?
    let play: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtworkView(data: portrait, size: 300, id: portrait.map { "artist-lineup:\(summary.id):\($0.count)" })
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.45), radius: 24, y: 18)
            Text(summary.displayName)
                .font(.system(size: 30, weight: .heavy))
                .tracking(-0.9)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .padding(.top, 6)
            Text(counts)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(FLActionPillStyle(isPrimary: true))
                Button("Open Artist", action: open)
                    .buttonStyle(FLActionPillStyle())
            }
            .padding(.top, 4)
        }
        .animation(.easeOut(duration: 0.25), value: summary.id)
    }

    private var counts: String {
        var parts: [String] = []
        let albums = summary.albums.count, singles = summary.singles.count, appears = summary.appearsOn.count
        if albums > 0 { parts.append("\(albums) album\(albums == 1 ? "" : "s")") }
        if singles > 0 { parts.append("\(singles) single\(singles == 1 ? "" : "s") & EP\(singles == 1 ? "" : "s")") }
        if appears > 0 { parts.append("\(appears) appearance\(appears == 1 ? "" : "s")") }
        if let plays { parts.append("\(plays) play\(plays == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Lineup layout

/// Flows names left to right, wrapping to new lines, baselines aligned
/// within each line so mixed sizes read like a poster. Each name is measured
/// once per change to the lineup, not on every pass.
private struct LineupLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    struct Cache {
        var sizes: [CGSize]
        var baselines: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache(sizes: [], baselines: [])
        cache.sizes.reserveCapacity(subviews.count)
        cache.baselines.reserveCapacity(subviews.count)
        for subview in subviews {
            let dimensions = subview.dimensions(in: .unspecified)
            cache.sizes.append(CGSize(width: dimensions.width, height: dimensions.height))
            cache.baselines.append(dimensions[.lastTextBaseline])
        }
        return cache
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(cache, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for line in arrange(cache, width: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                let size = cache.sizes[item]
                subviews[item].place(
                    at: CGPoint(x: x, y: y + line.baseline - cache.baselines[item]),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [Int] = []
        var width: CGFloat = 0
        var baseline: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { baseline + descent }
    }

    private func arrange(_ cache: Cache, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in cache.sizes.indices {
            let size = cache.sizes[index]
            let baseline = cache.baselines[index]
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.items.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.items.append(index)
            line.baseline = max(line.baseline, baseline)
            line.descent = max(line.descent, size.height - baseline)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
