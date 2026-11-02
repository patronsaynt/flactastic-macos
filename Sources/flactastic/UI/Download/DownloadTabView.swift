import SwiftUI
import AppKit

/// The Download tab, as one page. A single field takes a search or any link
/// — album, track or Spotify playlist — with the download options below it.
/// Typing searches the catalogue as you go; a link waits for Fetch. Your
/// Spotify playlists sit below the field while it's empty, search results
/// while it holds a search, and whatever is opened takes their place. The downloads panel slides in on the right once
/// something is downloading (or a playlist is rebuilding) and goes away
/// again when it's cleared.
///
/// Links resolve through the streamer registry (native providers when
/// configured, Lucida otherwise); Spotify playlist links, and playlists
/// picked from your account, go through the playlist rebuild coordinator,
/// which downloads every track and rebuilds the playlist in the library.
struct DownloadTabView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(StreamerRegistry.self) private var registry
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(PlaylistRebuildCoordinator.self) private var rebuilder
    @Environment(LucidaWebController.self) private var lucidaController
    @Environment(SpotifyAuthController.self) private var spotifyAuth
    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library

    @State private var pasteURL: String = ""

    /// The catalogue behind search. Deezer for now; any `CatalogSearching`
    /// whose links Lucida resolves can replace it.
    private let catalog: any CatalogSearching = DeezerCatalogSearch.shared
    @State private var searchResults: CatalogSearchResults?
    @State private var isSearching = false
    @State private var searchError: String?
    /// What's already in the library, for the In Library marks on results,
    /// opened albums and tracks, and playlists. Worked out off the main
    /// thread whenever the library changes, so marks appear as downloads land.
    @State private var ownership: LibraryOwnership?
    /// Bumped by Return (or Try again) to search at once instead of after
    /// the typing pause.
    @State private var searchNow = 0
    /// One-click downloads started from results, by result ID.
    @State private var quick: [String: QuickEntry] = [:]
    @FocusState private var fieldFocused: Bool
    @FocusState private var focusedResult: String?

    /// A resolved album / track / artist link.
    @State private var resolved: RemoteResolveResponse?
    @State private var isWorking: Bool = false
    @State private var error: String?

    /// A resolved Spotify playlist (from a link or from your account).
    @State private var resolvedPlaylist: RemotePlaylist?
    @State private var playlistTruncated: Bool = false
    @State private var isResolvingPlaylist: Bool = false
    @State private var playlistError: String?

    /// The cover of whatever is open.
    @State private var heroArtwork: NSImage?

    /// Drives the VPN reminder. Shown on the first visit per session while
    /// `settings.showVpnNotice` is on; not re-shown on later visits.
    @State private var showVpnSheet: Bool = false
    @State private var hasOfferedVpnSheet: Bool = false

    /// Download knobs (format, quality, region, metadata, compatibility),
    /// applied to every track enqueued from this page. Reset to defaults
    /// whenever a fresh link is fetched.
    @State private var options: LucidaOptions = .default

    /// The downloads panel hidden down to the small indicator. Resets once
    /// the queue empties, so the next download shows the panel again.
    @State private var queueCollapsed = false

    private static let queueWidth: CGFloat = 380
    private static let motion = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsQueue && !queueCollapsed {
                queuePanel
                    .frame(width: Self.queueWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsQueue && queueCollapsed {
                queueIndicator
                    .padding(.top, topBarInset + 24)
                    .padding(.trailing, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Self.motion, value: showsQueue)
        .animation(Self.motion, value: queueCollapsed)
        .onChange(of: showsQueue) { _, shows in
            if !shows { queueCollapsed = false }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .task {
            lucidaController.warmUp()
            if !hasOfferedVpnSheet && settings.showVpnNotice {
                hasOfferedVpnSheet = true
                showVpnSheet = true
            }
        }
        .task(id: openCoverURL) {
            heroArtwork = nil
            guard let url = openCoverURL else { return }
            if let result = await ArtworkAccent.load(url) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.35)) { heroArtwork = result.image }
            }
        }
        .task(id: library.tracksRevision) {
            let tracks = library.tracks
            let resolver = library.makeArtistResolver()
            let built = await Task.detached(priority: .userInitiated) {
                LibraryOwnership(tracks: tracks, resolver: resolver)
            }.value
            ownership = built
        }
        .sheet(isPresented: $showVpnSheet) {
            VpnNoticeSheet(showVpnNoticeAgain: Bindable(settings).showVpnNotice)
        }
    }

    // MARK: - State

    private enum PageState { case idle, loading, error, resolved }

    private enum QuickEntry {
        case resolving
        case queued(trackIDs: [String])
        case failed(String)
    }

    /// The field holds a link rather than a search.
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { return true }
        let hosts = ["open.spotify.com", "spotify.com", "tidal.com", "listen.tidal.com", "qobuz.com",
                     "play.qobuz.com", "open.qobuz.com", "deezer.com", "soundcloud.com", "on.soundcloud.com",
                     "music.apple.com", "music.amazon.", "music.youtube.com"]
        return hosts.contains { lower.hasPrefix($0) }
    }

    private var isLinkInput: Bool { Self.isLink(pasteURL) }

    /// The search the field holds, or nil when it's empty or a link.
    private var searchQuery: String? {
        let trimmed = pasteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || isLinkInput ? nil : trimmed
    }

    private var pageState: PageState {
        if isWorking || isResolvingPlaylist { return .loading }
        if error != nil || playlistError != nil { return .error }
        if resolved != nil || resolvedPlaylist != nil { return .resolved }
        return .idle
    }

    /// The downloads panel shows while anything is in it, or a playlist is
    /// being rebuilt (or its summary is waiting to be dismissed).
    private var showsQueue: Bool {
        if !downloads.jobs.isEmpty { return true }
        if case .idle = rebuilder.phase { return false }
        return true
    }

    private var openCoverURL: URL? {
        if let p = resolvedPlaylist { return RemoteCoverArt.best(p.coverArt)?.url }
        switch resolved {
        case .album(let a):    return RemoteCoverArt.best(a.coverArt)?.url
        case .track(let t):    return RemoteCoverArt.best(t.coverArt)?.url
        case .playlist(let p): return RemoteCoverArt.best(p.coverArt)?.url
        default:               return nil
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Download")
                    .font(.system(size: 72, weight: .heavy))
                    .tracking(-2.9)
                    .foregroundStyle(Theme.textPrimary)
                Text("Search, paste a link, or pick a Spotify playlist. Downloads at the highest available quality.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                pasteBar
                    .padding(.top, 30)
                ZStack(alignment: .leading) {
                    worksWith
                        .opacity(searchQuery == nil ? 1 : 0)
                        .offset(y: searchQuery == nil ? 0 : 4)
                    sourceNote
                        .opacity(searchQuery == nil ? 0 : 1)
                        .offset(y: searchQuery == nil ? 4 : 0)
                }
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: searchQuery == nil)
                .padding(.top, 14)
                optionsRow
                    .padding(.top, 18)
                    .padding(.top, 16)
                    .overlay(alignment: .top) { divider.padding(.top, 18) }

                Group {
                    switch pageState {
                    case .idle:     if searchQuery != nil { searchContent } else { spotifySection }
                    case .loading:  loadingState
                    case .error:    errorState
                    case .resolved: resolvedContent
                    }
                }
                .padding(.top, 30)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, topBarInset + 38)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.automatic)
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    /// One field for both: a link fetches on Return or Fetch, anything else
    /// searches as you type. The leading glyph turns into a link the moment
    /// a link is pasted, and Fetch only appears then.
    private var pasteBar: some View {
        let link = isLinkInput
        let hasText = !pasteURL.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 12) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .opacity(link ? 0 : 1)
                    .rotationEffect(.degrees(link ? 30 : 0))
                    .scaleEffect(link ? 0.6 : 1)
                Image(systemName: "link")
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(link ? 1 : 0)
                    .rotationEffect(.degrees(link ? 0 : -30))
                    .scaleEffect(link ? 1 : 0.6)
            }
            .font(.system(size: 16))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 18)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32), value: link)
            TextField("Search or paste a link", text: $pasteURL)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .disabled(pageState == .loading)
                .onSubmit(submit)
                .onKeyPress(.downArrow) {
                    guard let first = firstResultID else { return .ignored }
                    focusedResult = first
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard hasText else { return .ignored }
                    clearField()
                    return .handled
                }
            if pageState == .loading || isSearching {
                ProgressView().controlSize(.small)
            }
            if hasText && !link && searchResults != nil && pageState == .idle {
                Text("↓ to browse")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
            }
            if hasText {
                Button(action: clearField) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
            if link {
                Button("Fetch", action: resolve)
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .disabled(pageState == .loading)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: link)
        .padding(.leading, 22)
        .padding(.trailing, link ? 6 : 16)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .background(Theme.textPrimary.opacity(fieldFocused ? 0.08 : 0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(fieldFocused ? 0.18 : 0.1), lineWidth: 1))
        .task(id: SearchKey(query: searchQuery, now: searchNow)) { await runSearch() }
        .onChange(of: searchQuery) { _, query in
            // Typing a new search takes the page back to the results.
            if query != nil, pageState != .loading, resolved != nil || resolvedPlaylist != nil || error != nil || playlistError != nil {
                clearOpen()
            }
        }
    }

    /// Says what a search reaches: the catalogue it looks in, and that each
    /// download comes from the best copy Lucida can get, Hi-Res when one exists.
    private var sourceNote: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.qualityLossless).frame(width: 6, height: 6)
            (Text("Searching ")
             + Text(catalog.sourceName).foregroundColor(Theme.textSecondary).fontWeight(.semibold)
             + Text(" · downloads from the best source available, up to ")
             + Text("Hi-Res").foregroundColor(Theme.qualityLossless).fontWeight(.semibold)
             + Text("."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(height: 24)
    }

    private var worksWith: some View {
        HStack(spacing: 8) {
            Text("Links from")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, 4)
            ForEach(["Spotify", "Tidal", "Qobuz", "Deezer", "Amazon Music", "SoundCloud"], id: \.self) { service in
                Text(service)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
            }
        }
    }

    // MARK: - Download options

    /// Sits with the link field it applies to: format, quality (when the
    /// format has one), region, and the two tagging options.
    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Download as")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.trailing, 2)

                optionMenu(options.format.label) {
                    ForEach(LucidaOptions.Format.allCases) { format in
                        Button {
                            options.format = format
                            options.quality = format.qualities.first?.value
                        } label: {
                            if format == options.format {
                                Label(format.label, systemImage: "checkmark")
                            } else {
                                Text(format.label)
                            }
                        }
                    }
                }
                .help("Format")

                if !options.format.qualities.isEmpty {
                    let current = options.quality ?? options.format.qualities.first?.value
                    optionMenu(options.format.qualities.first(where: { $0.value == current })?.label ?? "Quality") {
                        ForEach(options.format.qualities) { q in
                            Button {
                                options.quality = q.value
                            } label: {
                                if q.value == current {
                                    Label(q.label, systemImage: "checkmark")
                                } else {
                                    Text(q.label)
                                }
                            }
                        }
                    }
                    .help("Quality")
                }

                HStack(spacing: 6) {
                    Text("Region")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("auto", text: $options.region)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 48)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
                .help("Region: leave as auto, or enter a country code")

                SheetTogglePill(title: "Embed tags & cover", isOn: $options.addMetadata)
                    .help("Write tags and artwork into each file")
                SheetTogglePill(title: "Player compatibility", isOn: $options.compatibility)
                    .help("Smaller cover and ID3v2.3, for older hardware")
            }
            Text("Applies to every track you download.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func optionMenu<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Search

    /// Restarts the search task when the query changes, or when Return asks
    /// for it now.
    private struct SearchKey: Equatable {
        let query: String?
        let now: Int
    }

    @ViewBuilder
    private var searchContent: some View {
        if let results = searchResults, !results.isEmpty {
            DownloadSearchResults(
                results: results,
                ownership: ownership ?? LibraryOwnership(),
                state: quickState,
                onOpen: openResult,
                onDownload: quickDownload,
                focus: $focusedResult,
                onLeaveTop: { focusedResult = nil; fieldFocused = true }
            )
            .opacity(isSearching ? 0.55 : 1)
            .animation(.easeOut(duration: 0.2), value: isSearching)
        } else if let searchError {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Search isn't reachable")
                Text(searchError)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 6)
                Button("Try again") { searchNow += 1 }
                    .buttonStyle(SheetPillStyle())
                    .padding(.top, 18)
            }
        } else if let results = searchResults, results.isEmpty, !isSearching {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Nothing on \(catalog.sourceName) for “\(results.query)”")
                Text("Try different words, or paste a link.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                Text("Searching \(catalog.sourceName)…")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 20)
        }
    }

    /// The first result ↓ moves to from the field.
    private var firstResultID: String? {
        guard pageState == .idle, searchQuery != nil, let results = searchResults else { return nil }
        return results.top?.id ?? results.tracks.first?.id ?? results.albums.first?.id
    }

    // MARK: - Spotify playlists (idle)

    private var spotifySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Your Spotify playlists")
                Spacer()
                if case .connected(let name) = spotifyAuth.state {
                    (Text("Connected as ") + Text(name).foregroundColor(Theme.textSecondary).fontWeight(.semibold))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if spotifyAuth.isConnected {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18)], alignment: .leading, spacing: 22) {
                    if settings.showSpotifyLikedSongs {
                        SpotifyPlaylistCard(playlist: SpotifyAuthController.likedSongsSummary) {
                            openPlaylist(SpotifyAuthController.likedSongsSummary)
                        }
                    }
                    ForEach(spotifyAuth.playlists) { playlist in
                        SpotifyPlaylistCard(playlist: playlist) { openPlaylist(playlist) }
                    }
                }
                .task {
                    if spotifyAuth.playlists.isEmpty { await spotifyAuth.loadPlaylists() }
                }
            } else {
                connectCard
            }
        }
    }

    private var connectCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(Theme.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect your Spotify account")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("List your own playlists here and download any of them in full. Or paste a public playlist link above.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                Task { await spotifyAuth.connect() }
            } label: {
                HStack(spacing: 8) {
                    if spotifyAuth.state == .connecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(spotifyAuth.state == .connecting ? "Connecting…" : "Connect")
                }
            }
            .buttonStyle(SheetPillStyle(isPrimary: true))
            .disabled(spotifyAuth.state == .connecting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Theme.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .heavy))
            .tracking(-0.4)
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Loading / error

    private var loadingState: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text("Fetching…")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 20)
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(playlistError != nil ? "Couldn't read that playlist" : "Couldn't fetch that link")
            Text(playlistError ?? error ?? "Check it's a track, album or playlist link from one of the services above.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 6)
            Button(searchQuery != nil ? "Back to results" : spotifyAuth.isConnected && playlistError != nil ? "Back to your playlists" : "Try another link", action: clearOpen)
                .buttonStyle(SheetPillStyle())
                .padding(.top, 18)
        }
    }

    // MARK: - Resolved

    @ViewBuilder
    private var resolvedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: clearOpen) {
                Label(searchQuery != nil ? "Back to results" : spotifyAuth.isConnected ? "Back to your playlists" : "Back", systemImage: "chevron.left")
            }
            .buttonStyle(QuietTextButtonStyle())
            .padding(.leading, -10)
            .padding(.bottom, 16)

            if let p = resolvedPlaylist {
                if playlistTruncated {
                    notice("Showing the first \(SpotifyPlaylistService.trackCap) tracks. Spotify's public preview caps longer playlists — connect your account to get every track.", color: Theme.qualityMid)
                        .padding(.bottom, 22)
                }
                collection(kind: "Playlist", title: p.title, meta: playlistMeta(p), tracks: p.tracks, cta: "Download playlist") {
                    rebuilder.rebuild(from: p, options: options)
                }
            } else {
                switch resolved {
                case .album(let a):
                    collection(kind: "Album", title: a.title, meta: albumMeta(a), tracks: a.tracks, cta: "Download album") {
                        enqueueWithOptions(a.tracks)
                    }
                case .track(let t):
                    collection(kind: "Track", title: t.title, meta: t.artists.map(\.name).joined(separator: ", "), tracks: [t], cta: "Download track") {
                        enqueueWithOptions([t])
                    }
                case .playlist(let p):
                    collection(kind: "Playlist", title: p.title, meta: p.creator.map { "by \($0)" } ?? "\(p.tracks.count) tracks", tracks: p.tracks, cta: "Download all") {
                        enqueueWithOptions(p.tracks)
                    }
                case .artist(let artist, _, _):
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Artist: \(artist.name)")
                        Text("Paste a track or album link to download.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                case .none:
                    EmptyView()
                }
            }
        }
    }

    /// Cover, kind, title, details and the download button, then the
    /// tracklist. One layout for every resolved kind.
    private func collection(kind: String, title: String, meta: String, tracks: [RemoteTrack], cta: String, onDownload: @escaping () -> Void) -> some View {
        let owned = tracks.filter(isOwned).count
        // A playlist still rebuilds from files already in the library, so it
        // keeps its button; an album or track that's all here has nothing to fetch.
        let nothingToFetch = owned == tracks.count && !tracks.isEmpty && kind != "Playlist"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 28) {
                cover
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(title)
                        .font(.system(size: 48, weight: .heavy))
                        .tracking(-1.9)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    Text(meta)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 10)
                    if owned > 0 && !nothingToFetch {
                        Text(owned == tracks.count
                             ? "All \(owned) already in your library"
                             : "\(owned) of \(tracks.count) already in your library")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 4)
                    }
                    if nothingToFetch {
                        Label(tracks.count == 1 ? "In your library" : "All in your library", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(height: 34)
                            .padding(.top, 18)
                    } else {
                        Button(action: onDownload) {
                            Label(cta, systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(SheetPillStyle(isPrimary: true))
                        .padding(.top, 18)
                    }
                }
                Spacer(minLength: 0)
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, number: track.trackNumber ?? index + 1)
                }
            }
            .padding(.top, 22)
        }
    }

    private var cover: some View {
        Group {
            if let heroArtwork {
                Image(nsImage: heroArtwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(Color.white.opacity(0.18))
                    )
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 20)
    }

    /// Already in the library, by the rule a download uses to skip it.
    private func isOwned(_ track: RemoteTrack) -> Bool {
        ownership?.owns(track) ?? false
    }

    /// The latest download of this track in the queue, if any.
    private func job(for track: RemoteTrack) -> DownloadCoordinator.Job? {
        downloads.jobs.last { $0.track.id == track.id }
    }

    private func trackRow(_ track: RemoteTrack, number: Int) -> some View {
        let job = job(for: track)
        let owned = isOwned(track)
        return HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(track.artists.map(\.name).joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if owned {
                Text("In Library")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                qualityTag(lossless: track.isLossless)
            }
            Text(FormatUtils.formatDuration(track.durationSeconds))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 48, alignment: .trailing)
            Group {
                if owned && job == nil {
                    InLibraryCheck()
                } else {
                    trackAction(track, job: job)
                }
            }
            .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .modifier(HoverFill())
    }

    private func qualityTag(lossless: Bool) -> some View {
        let color = lossless ? Theme.qualityLossless : Theme.qualityMid
        return Text(lossless ? "FLAC" : "Lossy")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 6)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func albumMeta(_ a: RemoteAlbum) -> String {
        var parts = [a.artists.map(\.name).joined(separator: ", ")]
        if let year = a.releaseYear { parts.append(String(year)) }
        let count = a.trackCount ?? a.tracks.count
        parts.append("\(count) track\(count == 1 ? "" : "s")")
        let total = a.tracks.compactMap(\.durationSeconds).reduce(0, +)
        if total > 0 { parts.append("\(Int(total / 60)) min") }
        return parts.joined(separator: " · ")
    }

    private func playlistMeta(_ p: RemotePlaylist) -> String {
        var parts: [String] = []
        if let creator = p.creator { parts.append("by \(creator)") }
        parts.append("\(p.tracks.count) track\(p.tracks.count == 1 ? "" : "s")")
        let total = p.tracks.compactMap(\.durationSeconds).reduce(0, +)
        if total > 0 { parts.append("\(Int(total / 60)) min") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Downloads panel

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Downloads")
                Spacer(minLength: 8)
                if downloads.jobs.contains(where: { $0.status.canCancel }) {
                    Button("Cancel all") { downloads.cancelAll() }
                        .buttonStyle(QuietTextButtonStyle())
                }
                if downloads.jobs.contains(where: { !$0.status.canCancel }) {
                    Button("Clear completed") { downloads.clearCompleted() }
                        .buttonStyle(QuietTextButtonStyle())
                }
                Button { queueCollapsed = true } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Hide downloads")
            }
            .padding(.horizontal, 28)
            .padding(.top, topBarInset + 38)
            .padding(.bottom, 10)

            rebuildCard
                .padding(.horizontal, 28)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(downloads.jobs.reversed()) { job in
                        jobRow(job)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.divider).frame(width: 1)
        }
    }

    /// The playlist rebuild's progress, then its summary until dismissed.
    @ViewBuilder
    private var rebuildCard: some View {
        switch rebuilder.phase {
        case .idle:
            EmptyView()
        case .fetchingArtwork:
            rebuildBox(tint: Theme.textPrimary.opacity(0.06)) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Preparing playlist…")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button("Cancel") { rebuilder.cancel() }
                        .buttonStyle(QuietTextButtonStyle())
                }
            }
        case .running(let current, let total):
            rebuildBox(tint: Theme.textPrimary.opacity(0.06)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Rebuilding playlist")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Button("Cancel") { rebuilder.cancel() }
                            .buttonStyle(QuietTextButtonStyle())
                    }
                    Text("\(current) of \(total) done")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                    progressBar(CGFloat(current) / CGFloat(max(total, 1)), color: Theme.textPrimary)
                }
            }
        case .finished(let summary):
            rebuildBox(tint: Theme.qualityCD.opacity(0.12)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.isResume ? "Playlist updated" : "Playlist rebuilt")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Button("Dismiss") { rebuilder.dismissSummary() }
                            .buttonStyle(QuietTextButtonStyle())
                    }
                    Text(rebuildSummaryLine(summary))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func rebuildBox<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 10)
    }

    private func rebuildSummaryLine(_ summary: PlaylistRebuildCoordinator.Summary) -> String {
        var parts = ["\(summary.downloaded) downloaded",
                     "\(summary.reused.count) already in library"]
        if summary.alreadyInPlaylist > 0 { parts.append("\(summary.alreadyInPlaylist) already in playlist") }
        parts.append("\(summary.failures.count) failed")
        return parts.joined(separator: " · ")
    }

    private func jobRow(_ job: DownloadCoordinator.Job) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.track.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(job.track.artists.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                if case .failed(let reason) = job.status {
                    // The full cause, selectable, in place of the bar.
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.qualityLow)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(reason)
                        .padding(.top, 2)
                } else if isInFlight(job.status) {
                    progressBar(jobProgress(job.status), color: Theme.textPrimary)
                        .padding(.top, 5)
                }
            }
            Spacer(minLength: 8)
            Text(jobStatusLabel(job.status))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(statusColor(job.status))
                .lineLimit(1)
                .fixedSize()
            Group {
                if job.status.canCancel {
                    Button { downloads.cancel(job.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { divider }
    }

    private func progressBar(_ fraction: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textPrimary.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 3)
    }

    private func isInFlight(_ status: DownloadCoordinator.JobStatus) -> Bool {
        switch status {
        case .downloading, .tagging, .finishing: return true
        default: return false
        }
    }

    /// Failed and cancelled downloads can be started again from the track row.
    private func isRetryable(_ status: DownloadCoordinator.JobStatus) -> Bool {
        switch status {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private func jobProgress(_ status: DownloadCoordinator.JobStatus) -> CGFloat {
        switch status {
        case .downloading(let r, let t):
            if let t, t > 0 { return CGFloat(Double(r) / Double(t)) }
            return 0.05
        case .tagging, .finishing, .completed: return 1
        default: return 0
        }
    }

    private func statusColor(_ status: DownloadCoordinator.JobStatus) -> Color {
        switch status {
        case .completed, .skipped: return Theme.qualityCD
        case .failed:              return Theme.qualityLow
        default:                   return Theme.textTertiary
        }
    }

    private func jobStatusLabel(_ status: DownloadCoordinator.JobStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .downloading(let r, let t):
            if let t, t > 0 {
                return "Downloading… \(Int((Double(r) / Double(t)) * 100))%"
            }
            return "Downloading… \(r / 1024) KB"
        case .tagging:    return "Tagging…"
        case .finishing:  return "Moving into library…"
        case .completed:  return "Done"
        case .failed:     return "Failed"
        case .cancelled:  return "Cancelled"
        case .skipped:    return "Already in library"
        }
    }

    /// The track row's button slot, a fixed size so the row never shifts:
    /// the download arrow, then a progress ring while the track is on its
    /// way, then a check. A failed or cancelled track gets its arrow back.
    @ViewBuilder
    private func trackAction(_ track: RemoteTrack, job: DownloadCoordinator.Job?) -> some View {
        if let job, isInFlight(job.status) || isQueued(job.status) {
            ProgressRing(fraction: ringFraction(job.status))
                .frame(width: 16, height: 16)
                .help(jobStatusLabel(job.status))
        } else if let job, !isRetryable(job.status) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.qualityCD)
                .help(jobStatusLabel(job.status))
        } else {
            Button { enqueueWithOptions([track]) } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(job == nil ? Theme.textTertiary : Theme.qualityLow)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(job == nil ? "Download track" : "\(jobStatusLabel(job!.status)) — download again")
        }
    }

    /// Nil (a spinning ring) while queued or before the size is known.
    private func ringFraction(_ status: DownloadCoordinator.JobStatus) -> CGFloat? {
        switch status {
        case .queued: return nil
        case .downloading(_, let total): return (total ?? 0) > 0 ? jobProgress(status) : nil
        default: return jobProgress(status)
        }
    }

    private func isQueued(_ status: DownloadCoordinator.JobStatus) -> Bool {
        if case .queued = status { return true }
        return false
    }

    // MARK: - Collapsed indicator

    /// The downloads panel hidden: a small glass pill with overall progress
    /// and what's left. Click it to bring the panel back.
    private var queueIndicator: some View {
        let jobs = downloads.jobs
        let active = jobs.filter { $0.status.canCancel }.count
        let finished = jobs.count - active
        var fraction: CGFloat? = jobs.isEmpty ? nil : CGFloat(finished) / CGFloat(jobs.count)
        var label = active > 0 ? "\(active) downloading" : "\(finished) done"
        switch rebuilder.phase {
        case .running(let current, let total):
            fraction = CGFloat(current) / CGFloat(max(total, 1))
            label = "Rebuilding \(current)/\(total)"
        case .fetchingArtwork:
            fraction = nil
            label = "Preparing playlist"
        case .finished:
            label = active > 0 ? label : "Playlist rebuilt"
        case .idle:
            break
        }
        let busy = active > 0 || { if case .running = rebuilder.phase { return true }; if case .fetchingArtwork = rebuilder.phase { return true }; return false }()
        return Button { queueCollapsed = false } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressRing(fraction: fraction)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.qualityCD)
                }
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show downloads")
    }

    // MARK: - Actions

    /// Return: a link fetches, a search runs without waiting for the pause.
    private func submit() {
        if isLinkInput { resolve() } else if searchQuery != nil { searchNow += 1 }
    }

    private func clearField() {
        pasteURL = ""
        clearOpen()
        fieldFocused = true
    }

    /// Searches after a short pause in typing (none when Return asked).
    /// Earlier results stay on screen, dimmed, until the new ones arrive.
    private func runSearch() async {
        guard let query = searchQuery else {
            isSearching = false
            return
        }
        if searchResults?.query != query || searchError != nil {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        isSearching = true
        do {
            let results = try await catalog.search(query)
            guard !Task.isCancelled else { return }
            searchResults = results
            searchError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSearching = false
    }

    /// A result opens just as its link would if pasted.
    private func openResult(_ result: CatalogResult) {
        clearOpen()
        focusedResult = nil
        isWorking = true
        options = .default
        Task {
            do {
                resolved = try await registry.resolve(result.link)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            isWorking = false
        }
    }

    /// Lists the result's tracks through Lucida and queues them all with
    /// the current options, without leaving the results.
    private func quickDownload(_ result: CatalogResult) {
        if case .resolving? = quick[result.id] { return }
        quick[result.id] = .resolving
        Task {
            do {
                let tracks: [RemoteTrack]
                switch try await registry.resolve(result.link) {
                case .album(let album): tracks = album.tracks
                case .track(let track): tracks = [track]
                case .playlist(let playlist): tracks = playlist.tracks
                case .artist: tracks = []
                }
                guard !tracks.isEmpty else {
                    quick[result.id] = .failed("Lucida found nothing to download.")
                    return
                }
                enqueueWithOptions(tracks)
                quick[result.id] = .queued(trackIDs: tracks.map(\.id))
            } catch {
                quick[result.id] = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't start the download.")
            }
        }
    }

    /// A result's download, read from the queue: overall progress across
    /// its tracks, a check once every one is in, a failure if any didn't make it.
    private func quickState(_ result: CatalogResult) -> QuickDownloadState {
        switch quick[result.id] {
        case nil: return .idle
        case .resolving: return .resolving
        case .failed(let message): return .failed(message)
        case .queued(let ids):
            let jobs = ids.compactMap { id in downloads.jobs.last { $0.track.id == id } }
            // Cleared from the panel after finishing.
            guard !jobs.isEmpty else { return .done }
            if jobs.contains(where: { isInFlight($0.status) || isQueued($0.status) }) {
                if jobs.allSatisfy({ isQueued($0.status) }) { return .progress(nil) }
                let total = jobs.reduce(CGFloat(0)) { $0 + jobProgress($1.status) }
                return .progress(total / CGFloat(jobs.count))
            }
            if jobs.contains(where: { isRetryable($0.status) }) {
                let failed = jobs.filter { isRetryable($0.status) }.count
                return .failed(failed == 1 ? "A track didn't download." : "\(failed) tracks didn't download.")
            }
            return .done
        }
    }

    /// Back to the idle page (your playlists), clearing whatever was open.
    private func clearOpen() {
        resolved = nil
        error = nil
        resolvedPlaylist = nil
        playlistTruncated = false
        playlistError = nil
    }

    private func resolve() {
        let trimmed = pasteURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        clearOpen()
        let withScheme = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil else {
            error = "That URL doesn't look valid."
            return
        }
        // Spotify playlists go through the rebuild coordinator's resolver,
        // not Lucida (whose metadata endpoint fails on playlists).
        if SpotifyPlaylistService.playlistID(from: url) != nil {
            resolvePlaylist(url)
            return
        }
        isWorking = true
        // A fresh link starts from the default options, so the last one's
        // choices don't silently carry over.
        options = .default
        Task {
            do {
                resolved = try await registry.resolve(url)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            isWorking = false
        }
    }

    /// A public Spotify playlist link, through the no-auth embed path (capped
    /// at `SpotifyPlaylistService.trackCap` tracks).
    private func resolvePlaylist(_ url: URL) {
        isResolvingPlaylist = true
        options = .default
        Task {
            do {
                let result = try await rebuilder.resolve(url)
                resolvedPlaylist = result.playlist
                playlistTruncated = result.wasTruncated
            } catch {
                playlistError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            isResolvingPlaylist = false
        }
    }

    /// One of your own playlists (or Liked Songs), with your account's token.
    private func openPlaylist(_ p: SpotifyAuthController.PlaylistSummary) {
        clearOpen()
        isResolvingPlaylist = true
        options = .default
        Task {
            do {
                let token = try await spotifyAuth.validAccessToken()
                let result = p.id == SpotifyAuthController.likedSongsID
                    ? try await rebuilder.resolveLikedSongs(userToken: token)
                    : try await rebuilder.resolve(p.externalURL, userToken: token)
                resolvedPlaylist = result.playlist
                playlistTruncated = result.wasTruncated
            } catch {
                playlistError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            isResolvingPlaylist = false
        }
    }

    /// Stamp the current options on each track via the Lucida provider, then
    /// hand the tracks to the coordinator. The provider drains its options
    /// dictionary as `getStream` runs, so old entries don't pile up.
    private func enqueueWithOptions(_ tracks: [RemoteTrack]) {
        if let lucida = registry.provider(serviceID: "lucida") as? LucidaWebProvider {
            for t in tracks { lucida.setOptions(options, for: t) }
        }
        downloads.enqueue(tracks)
    }
}

/// A small ring: the arc fills with `fraction`, or spins when it's nil
/// (queued, or no size known yet).
struct ProgressRing: View {
    let fraction: CGFloat?
    var tint: Color = Theme.textPrimary

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction.map { max(0.04, min(1, $0)) } ?? 0.28)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(fraction == nil && spinning ? 360 : 0))
                .animation(fraction == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.25), value: spinning)
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .onAppear { spinning = true }
        .accessibilityLabel(fraction.map { "\(Int($0 * 100)) percent" } ?? "Waiting")
    }
}

/// A faint fill behind a row while the pointer is over it.
private struct HoverFill: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(isHovering ? 0.05 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - VPN reminder

/// Shown on the first Download visit per session until "Don't show this
/// again" is ticked.
private struct VpnNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Inverse of "Don't show this again" — bound to `Settings.showVpnNotice`.
    @Binding var showVpnNoticeAgain: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Protect your connection")
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(Theme.textPrimary)
            Text("Always use a VPN when downloading, and only download music you already own or have a license to. Happy listening.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            HStack {
                Toggle(isOn: Binding(
                    get: { !showVpnNoticeAgain },
                    set: { showVpnNoticeAgain = !$0 }
                )) {
                    Text("Don't show this again")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button("Got it") { dismiss() }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(width: 460, alignment: .leading)
        .background(Theme.surface)
    }
}

// MARK: - Spotify playlist tile

/// A Spotify playlist in the grid: square cover that lifts on hover, name
/// and count beneath.
private struct SpotifyPlaylistCard: View {
    let playlist: SpotifyAuthController.PlaylistSummary
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    if let url = playlist.coverArtURL {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    } else {
                        LinearGradient(
                            colors: playlist.id == SpotifyAuthController.likedSongsID
                                ? [Color(red: 0.35, green: 0.16, blue: 0.5), Color(red: 0.1, green: 0.08, blue: 0.22)]
                                : [Color(white: 0.16), Color(white: 0.07)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(
                            Image(systemName: playlist.id == SpotifyAuthController.likedSongsID ? "heart.fill" : "music.note.list")
                                .font(.system(size: 28, weight: .thin))
                                .foregroundStyle(Color.white.opacity(playlist.id == SpotifyAuthController.likedSongsID ? 0.85 : 0.22)))
                    }
                }
                // Square slot first, cover overlaid and clipped to it, so
                // non-square Spotify mosaics are cropped rather than widening
                // the tile off-grid.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(SquareSlot())
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(isHovering ? 0.45 : 0.3), radius: isHovering ? 16 : 10, y: isHovering ? 12 : 8)
                .offset(y: isHovering ? -3 : 0)
                .padding(.bottom, 8)

                Text(playlist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(playlist.trackCount < 0 ? "Your saved tracks" : "\(playlist.trackCount) tracks")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3)) { isHovering = hovering }
        }
        .help(playlist.owner.map { "\(playlist.name) · by \($0)" } ?? playlist.name)
    }
}

/// Fixes content to a square of the proposed width, centering and clipping
/// whatever is inside.
struct SquareSlot: ViewModifier {
    func body(content: Content) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipped()
    }
}
