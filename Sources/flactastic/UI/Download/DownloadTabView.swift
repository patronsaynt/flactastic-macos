import SwiftUI
import AppKit

/// Full-page Download tab. The user pastes a streaming-service URL and
/// presses return; the registry routes it to the appropriate provider
/// (native Qobuz/Deezer when configured, Lucida otherwise) and we show the
/// resolved track/album plus any in-flight downloads.
struct DownloadTabView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(StreamerRegistry.self) private var registry
    @Environment(DownloadCoordinator.self) private var downloads
    @Environment(PlaylistRebuildCoordinator.self) private var rebuilder
    @Environment(LucidaWebController.self) private var lucidaController
    @Environment(SpotifyAuthController.self) private var spotifyAuth
    @Environment(Settings.self) private var settings

    /// Which sub-screen of the Download tab is showing. The user lands on
    /// `.chooser` (two panels) and drills into one mode at a time.
    private enum Mode { case chooser, albumsTracks, playlists }
    @State private var mode: Mode = .chooser

    /// Which chooser panel the pointer is over, driving the lift/glass
    /// hover treatment on the landing screen. `nil` = nothing hovered.
    private enum PanelSide { case left, right }
    @State private var hovered: PanelSide?

    /// Albums & Tracks screen: whether the collapsible Lucida options panel
    /// is expanded, and whether the docked downloads drawer is open.
    @State private var optionsOpen = false
    @State private var drawerOpen = false

    /// Cover art for the resolved item and the accent sampled from it. When no
    /// art (or no vibrant color) is available, the screen falls back to the
    /// hi-res turquoise quality tint, matching the left chooser panel.
    @State private var heroArtwork: NSImage?
    @State private var heroAccent: Color?

    /// Accent for the Albums & Tracks screen — the selected album's color when
    /// known, else the default tint. `onAccent` is the readable foreground for
    /// fills painted in `atAccent`.
    private var atAccent: Color { heroAccent ?? Theme.qualityLossless }
    private let onAccent = Color.black

    /// Largest cover art URL for whatever is currently resolved, if any.
    private var resolvedCoverURL: URL? {
        switch resolved {
        case .album(let a):    return RemoteCoverArt.best(a.coverArt)?.url
        case .track(let t):    return RemoteCoverArt.best(t.coverArt)?.url
        case .playlist(let p): return RemoteCoverArt.best(p.coverArt)?.url
        default:               return nil
        }
    }

    @State private var pasteURL: String = ""
    @State private var resolved: RemoteResolveResponse?
    @State private var isWorking: Bool = false
    @State private var error: String?

    // Playlists mode — resolved separately from Spotify's embed endpoint.
    @State private var playlistURL: String = ""
    @State private var resolvedPlaylist: RemotePlaylist?
    @State private var playlistTruncated: Bool = false
    @State private var isResolvingPlaylist: Bool = false
    @State private var playlistError: String?
    /// Drives the VPN advisory sheet. Set once on first appearance per
    /// session when `settings.showVpnNotice` is true; suppressed afterwards
    /// so navigating away and back doesn't re-pop the modal.
    @State private var showVpnSheet: Bool = false
    @State private var hasOfferedVpnSheet: Bool = false
    /// Per-paste download knobs (region, format, metadata, compat). Reset to
    /// defaults each time the user pastes a fresh URL. Applied to every
    /// track that gets enqueued from the resolved view below.
    @State private var options: LucidaOptions = .default

    var body: some View {
        content
            .padding(.top, topBarInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .task {
            lucidaController.warmUp()
            // Surface the VPN advisory on first Downloads-tab entry per
            // session. After the user closes it, we don't re-pop on
            // subsequent tab switches.
            if !hasOfferedVpnSheet && settings.showVpnNotice {
                hasOfferedVpnSheet = true
                showVpnSheet = true
            }
        }
        .sheet(isPresented: $showVpnSheet) {
            VpnNoticeSheet(showVpnNoticeAgain: Bindable(settings).showVpnNotice)
        }
    }

    // The chooser is a full-bleed centred landing screen of its own; the
    // drill-in modes keep the original back-button header + padded layout.
    @ViewBuilder
    private var content: some View {
        switch mode {
        case .chooser:
            chooserScreen
        case .albumsTracks:
            albumsTracksScreen
        case .playlists:
            playlistsScreen
        }
    }

    // MARK: - Header

    // MARK: - Chooser

    /// Full-bleed landing screen: a centred header over two large choice
    /// panels. Hovering a panel lifts it above a glass scrim while the rest
    /// of the screen blurs and dims behind it. Mirrors the Claude Design
    /// "Download Page" template.
    private var chooserScreen: some View {
        VStack(spacing: 0) {
            chooserHeader
                .padding(.top, 52)
                .padding(.horizontal, 48)
                .padding(.bottom, Theme.Spacing.sm)
                .blur(radius: hovered != nil ? 8 : 0)
                .opacity(hovered != nil ? 0.55 : 1)

            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                choicePanel(
                    side: .left,
                    icon: "opticaldisc.fill",
                    eyebrow: "Individual",
                    title: "Tracks & Albums",
                    subtitle: "Hand-pick singles or grab a complete album. Each file in full studio fidelity, exactly as it was mastered.",
                    cta: "Browse library",
                    accent: Theme.qualityLossless
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { hovered = nil; mode = .albumsTracks }
                }
                choicePanel(
                    side: .right,
                    icon: "music.note.list",
                    eyebrow: "Collections",
                    title: "Playlists",
                    subtitle: "Download a whole playlist in a single pass. We bundle every track at the highest fidelity it's available in.",
                    cta: "View playlists",
                    accent: Theme.qualityCD
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { hovered = nil; mode = .playlists }
                }
            }
            .frame(maxWidth: 1140)
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: hovered)
    }

    private var chooserHeader: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: 9) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 13, weight: .regular))
                Text("FLACtastic")
                    .font(.system(size: 11))
                    .tracking(1.5)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Theme.textTertiary)

            Text("Download")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("Choose what you'd like to pull down — every file arrives in its original lossless quality.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
    }

    private func choicePanel(
        side: PanelSide,
        icon: String,
        eyebrow: String,
        title: String,
        subtitle: String,
        cta: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hovered == side
        let dimmed = hovered != nil && !isHovered
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.gray.opacity(0.10))
                        Image(systemName: icon)
                            .font(.system(size: 30, weight: .regular))
                    }
                    .frame(width: 64, height: 64)
                    Spacer()
                    Text(eyebrow)
                        .font(.system(size: 11))
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: Theme.Spacing.xl)

                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.bottom, 10)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(.bottom, Theme.Spacing.xl)
                HStack(spacing: Theme.Spacing.sm) {
                    Text(cta)
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 380, alignment: .leading)
            .padding(36)
            .foregroundStyle(isHovered ? accent : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isHovered ? Theme.surfaceElevated : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isHovered ? accent : Theme.divider, lineWidth: 1)
            )
            .shadow(color: isHovered ? accent.opacity(0.35) : .clear,
                    radius: isHovered ? 40 : 0, x: 0, y: isHovered ? 22 : 0)
            .scaleEffect(isHovered ? 1.04 : 1)
            .offset(y: isHovered ? -14 : 0)
            .blur(radius: dimmed ? 8 : 0)
            .opacity(dimmed ? 0.55 : 1)
            .zIndex(isHovered ? 1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = side }
            else if hovered == side { hovered = nil }
        }
    }

    // MARK: - Albums & Tracks mode

    /// The drill-in screen state, derived from the existing resolve pipeline.
    private enum ATState { case empty, loading, error, resolved }
    private var atState: ATState {
        if isWorking { return .loading }
        if error != nil { return .error }
        if resolved != nil { return .resolved }
        return .empty
    }

    /// Full-bleed Albums & Tracks screen: a refined header, a body that
    /// swaps between empty / resolving / error / resolved states, and a
    /// downloads drawer docked at the bottom. Mirrors the Claude Design
    /// "Tracks & Albums" template; all the underlying resolve/enqueue
    /// plumbing is unchanged.
    private var albumsTracksScreen: some View {
        VStack(spacing: 0) {
            albumsTracksHeader

            Group {
                switch atState {
                case .empty:    atEmptyState
                case .loading:  atLoadingState
                case .error:    atErrorState
                case .resolved: atResolvedScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !downloads.jobs.isEmpty { downloadsDrawer }
        }
        // Pull cover art for the resolved item and recolor the screen to match.
        // Keyed on the URL so it reloads when the user resolves something new
        // and clears when nothing is resolved.
        .task(id: resolvedCoverURL) {
            heroArtwork = nil
            heroAccent = nil
            guard let url = resolvedCoverURL else { return }
            if let result = await ArtworkAccent.load(url) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    heroArtwork = result.image
                    heroAccent = result.accent
                }
            }
        }
    }

    // ── Header ───────────────────────────────────────────────────────────

    private var albumsTracksHeader: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { mode = .chooser }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surfaceElevated))
            }
            .buttonStyle(.plain)
            .help("Back to Download")

            VStack(alignment: .leading, spacing: 3) {
                Text("Albums & Tracks")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Paste a link from Spotify, Tidal, Qobuz, Amazon Music, or SoundCloud.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            // Once something's resolved (or errored), keep a compact paste
            // bar handy so the user can fetch another link without going back.
            if resolved != nil || error != nil {
                pasteBar(large: false).frame(width: 340)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// Shared paste field — `large` is the centred empty-state hero input;
    /// the compact form lives in the header. Both submit through `resolve()`.
    private func pasteBar(large: Bool) -> some View {
        HStack(spacing: large ? 12 : 8) {
            Image(systemName: "link")
                .font(.system(size: large ? 18 : 15, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            TextField("Paste a track or album URL", text: $pasteURL)
                .textFieldStyle(.plain)
                .font(.system(size: large ? 15 : 13))
                .disabled(isWorking)
                .onSubmit(resolve)
            Button(action: resolve) {
                HStack(spacing: 8) {
                    Text("Fetch")
                    if large {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .font(.system(size: large ? 14 : 12, weight: .semibold))
                .foregroundStyle(large ? onAccent : Theme.textPrimary)
                .padding(.horizontal, large ? 22 : 13)
                .frame(height: large ? 40 : 28)
                .background(Capsule().fill(large ? atAccent : Theme.surfaceElevated))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, large ? 20 : 14)
        .padding(.trailing, large ? 8 : 6)
        .frame(height: large ? 56 : 38)
        .background(
            RoundedRectangle(cornerRadius: large ? 14 : 19).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: large ? 14 : 19)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    // ── Empty / paste-prompt ──────────────────────────────────────────────

    private var atEmptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(atAccent.opacity(0.16)).frame(width: 96, height: 96).blur(radius: 22)
                Circle().fill(Theme.surfaceElevated).frame(width: 76, height: 76)
                Image(systemName: "link")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(atAccent)
            }
            .padding(.bottom, 26)

            Text("Paste a link to get started")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Drop in a track or album URL and we'll resolve every track at its highest available fidelity.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 10)
                .padding(.bottom, 30)

            pasteBar(large: true).frame(maxWidth: 560)

            HStack(spacing: 8) {
                Text("Works with")
                    .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.trailing, 4)
                ForEach(["Spotify", "Tidal", "Qobuz", "Amazon Music", "SoundCloud"], id: \.self) { svc in
                    Text(svc)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.surface))
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                }
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // ── Resolving ─────────────────────────────────────────────────────────

    private var atLoadingState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView().controlSize(.large).tint(atAccent)
            Text("Fetching…")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // ── Error ─────────────────────────────────────────────────────────────

    private var atErrorState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.qualityLow.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Theme.qualityLow)
            }
            .padding(.bottom, 22)

            Text("Couldn't fetch that link")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(error ?? "That URL doesn't look valid, or the content is region-locked or private. Check the link and try again.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 10)
                .padding(.bottom, 28)

            Button {
                error = nil
                resolved = nil
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Try another link")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)
                .frame(height: 44)
                .background(Capsule().fill(Theme.surfaceElevated))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // ── Resolved ──────────────────────────────────────────────────────────

    private var atResolvedScroll: some View {
        ScrollView {
            atResolvedBody
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var atResolvedBody: some View {
        switch resolved {
        case .album(let a):
            collectionView(kind: "Album", title: a.title, meta: albumMeta(a),
                           tracks: a.tracks, downloadAllLabel: "Download album") {
                enqueueWithOptions(a.tracks)
            }
        case .track(let t):
            collectionView(kind: "Track", title: t.title,
                           meta: t.artists.map(\.name).joined(separator: ", "),
                           tracks: [t], downloadAllLabel: "Download track") {
                enqueueWithOptions([t])
            }
        case .playlist(let p):
            collectionView(kind: "Playlist", title: p.title,
                           meta: p.creator.map { "by \($0)" } ?? "\(p.tracks.count) tracks",
                           tracks: p.tracks, downloadAllLabel: "Download all") {
                enqueueWithOptions(p.tracks)
            }
        case .artist(let artist, _, _):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Artist: \(artist.name)")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Paste a track or album URL to download.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .none:
            EmptyView()
        }
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

    /// The album/track/playlist hero + collapsible options + tracklist. One
    /// renderer for every resolved kind so the layout stays consistent.
    private func collectionView(
        kind: String,
        title: String,
        meta: String,
        tracks: [RemoteTrack],
        downloadAllLabel: String,
        onDownloadAll: @escaping () -> Void
    ) -> some View {
        let allLossless = !tracks.isEmpty && tracks.allSatisfy(\.isLossless)
        return VStack(alignment: .leading, spacing: 0) {
            // Hero
            HStack(alignment: .bottom, spacing: 28) {
                artworkHero
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        qualityBadge(lossless: allLossless)
                        Text(kind)
                            .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.bottom, 11)

                    Text(title)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    Text(meta)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 22)

                    HStack(spacing: 12) {
                        Button(action: onDownloadAll) {
                            HStack(spacing: 9) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(downloadAllLabel)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(onAccent)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(Capsule().fill(atAccent))
                        }
                        .buttonStyle(.plain)

                        optionsToggle
                    }
                }
                Spacer(minLength: 0)
            }

            if optionsOpen { albumsOptionsPanel.padding(.top, 22) }

            trackList(tracks).padding(.top, 30)
        }
    }

    private var artworkHero: some View {
        ZStack {
            // Colored glow behind the cover, tinted to the sampled accent.
            RoundedRectangle(cornerRadius: 14)
                .fill(atAccent.opacity(0.30))
                .frame(width: 160, height: 160)
                .blur(radius: 30)
                .offset(y: 10)

            Group {
                if let art = heroArtwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Placeholder until art loads (or when none is available).
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(
                        RadialGradient(
                            colors: [Color.white.opacity(0.10), .clear],
                            center: .topLeading, startRadius: 0, endRadius: 150))
                    .overlay(
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(Color.white.opacity(0.18)))
                }
            }
            .frame(width: 176, height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.55), radius: 25, x: 0, y: 18)
        }
    }

    private func qualityBadge(lossless: Bool) -> some View {
        Text(lossless ? "FLAC" : "Lossy")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(lossless ? atAccent.opacity(0.14) : Color.clear))
            .foregroundStyle(lossless ? atAccent : Theme.textTertiary)
    }

    // ── Collapsible options ───────────────────────────────────────────────

    private var optionsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { optionsOpen.toggle() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                Text(optionsSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Rectangle().fill(Theme.divider).frame(width: 1, height: 16)
                Image(systemName: optionsOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .frame(height: 44)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var optionsSummary: String {
        var parts: [String] = []
        parts.append(options.format == .original ? "Original quality" : options.format.label)
        if options.format.requiresQuality, let q = options.quality,
           let label = options.format.qualities.first(where: { $0.value == q })?.label {
            parts.append(label)
        }
        parts.append("Region \(options.region.isEmpty ? "auto" : options.region)")
        return parts.joined(separator: "   ·   ")
    }

    private var albumsOptionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Download options")
                    .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                Rectangle().fill(Theme.divider).frame(height: 1)
                Text("Applies to every track you download")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Format").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: $options.format) {
                        ForEach(LucidaOptions.Format.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 200)
                    .onChange(of: options.format) { _, newFormat in
                        options.quality = newFormat.qualities.first?.value
                    }
                }
                if !options.format.qualities.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Quality").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Picker("", selection: qualityBinding) {
                            ForEach(options.format.qualities) { q in
                                Text(q.label).tag(q.value)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 170)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Region").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    TextField("auto or country code", text: $options.region)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                }
            }

            HStack(spacing: 10) {
                optionCheck(isOn: $options.addMetadata,
                            title: "Embed metadata + cover art",
                            subtitle: "Tags & artwork written into each file")
                optionCheck(isOn: $options.compatibility,
                            title: "Player compatibility",
                            subtitle: "Smaller cover, ID3v2.3 for older hardware")
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.divider, lineWidth: 1))
    }

    private func optionCheck(isOn: Binding<Bool>, title: String, subtitle: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn.wrappedValue ? atAccent : Color.clear)
                        .frame(width: 19, height: 19)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isOn.wrappedValue ? Color.clear : Theme.textTertiary, lineWidth: 1.5)
                        )
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(onAccent)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 12).padding(.trailing, 15).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceElevated))
        }
        .buttonStyle(.plain)
    }

    // ── Track list ────────────────────────────────────────────────────────

    private func trackList(_ tracks: [RemoteTrack]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("#")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 26)
                Text("Title")
                    .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("Length")
                    .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.trailing, 64)
            }
            .padding(.horizontal, 4).padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.divider).frame(height: 1)
            }

            ForEach(tracks) { albumTrackRow($0) }
        }
    }

    private func albumTrackRow(_ t: RemoteTrack) -> some View {
        HStack(spacing: 14) {
            Text(t.trackNumber.map { String(format: "%02d", $0) } ?? "–")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title)
                    .font(.system(size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(t.artists.map(\.name).joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            if t.isLossless {
                Text("FLAC")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(atAccent.opacity(0.14)))
                    .foregroundStyle(atAccent)
            } else {
                Text("Lossy")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(FormatUtils.formatDuration(t.durationSeconds))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
            Button { enqueueWithOptions([t]) } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Download track")
        }
        .padding(.horizontal, 4).padding(.vertical, 10)
    }

    // ── Downloads drawer (docked) ─────────────────────────────────────────

    private var downloadsDrawer: some View {
        let active = downloads.jobs.filter { $0.status.canCancel }.count
        let done = downloads.jobs.filter { if case .completed = $0.status { return true }; return false }.count
        let summary = active > 0 ? "\(active) active · \(done) done" : "\(downloads.jobs.count) complete"
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(atAccent.opacity(0.14)).frame(width: 30, height: 30)
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(atAccent)
                }
                Text("Downloads")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if active > 0 {
                    Button("Cancel all") { downloads.cancelAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Button("Clear completed") { downloads.clearCompleted() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: drawerOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { drawerOpen.toggle() }
            }

            if drawerOpen {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.jobs) { drawerJobRow($0) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: -10)
    }

    private func drawerJobRow(_ job: DownloadCoordinator.Job) -> some View {
        HStack(spacing: 14) {
            Circle().fill(jobAccentColor(job.status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(job.track.title)
                        .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(job.track.artists.map(\.name).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                if case .failed(let reason) = job.status {
                    // Full cause in place of the bar — the status column is
                    // too narrow for multi-source reasons.
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.qualityLow)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(reason)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.divider)
                            Capsule().fill(jobAccentColor(job.status))
                                .frame(width: geo.size.width * jobProgress(job.status))
                        }
                    }
                    .frame(height: 4)
                }
            }
            Text(jobStatusLabel(job.status))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .trailing)
            Group {
                if job.status.canCancel {
                    Button { downloads.cancel(job.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                } else if case .completed = job.status {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.qualityCD)
                        .frame(width: 26, height: 26)
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
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

    private func jobAccentColor(_ status: DownloadCoordinator.JobStatus) -> Color {
        switch status {
        case .downloading, .tagging, .finishing: return atAccent
        case .completed: return Theme.qualityCD
        case .failed:    return Theme.qualityLow
        default:         return Theme.textTertiary
        }
    }

    // MARK: - Playlists mode

    /// Playlists screen state. Mirrors the Claude Design "Playlists" template:
    /// connect your account to browse your own playlists, or paste a public
    /// link. The resolved view reuses the Albums & Tracks download layout.
    private enum PLState { case notConnected, grid, resolving, error, resolved }
    private var plState: PLState {
        if isResolvingPlaylist { return .resolving }
        if playlistError != nil { return .error }
        if resolvedPlaylist != nil { return .resolved }
        if spotifyAuth.isConnected { return .grid }
        return .notConnected
    }

    /// Best cover URL for the resolved playlist — drives the artwork + accent.
    private var plCoverURL: URL? {
        guard let p = resolvedPlaylist else { return nil }
        return RemoteCoverArt.best(p.coverArt)?.url
    }

    private var playlistsScreen: some View {
        VStack(spacing: 0) {
            playlistsHeader

            if showRebuildBar { rebuildTopBar }

            Group {
                switch plState {
                case .notConnected: plNotConnectedState
                case .grid:         plGridState
                case .resolving:    atLoadingState
                case .error:        plErrorState
                case .resolved:     plResolvedScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !downloads.jobs.isEmpty { downloadsDrawer }
        }
        // Recolor to the resolved playlist's cover, same as Albums & Tracks.
        .task(id: plCoverURL) {
            heroArtwork = nil
            heroAccent = nil
            guard let url = plCoverURL else { return }
            if let result = await ArtworkAccent.load(url) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    heroArtwork = result.image
                    heroAccent = result.accent
                }
            }
        }
    }

    // ── Header ───────────────────────────────────────────────────────────

    private var playlistsHeader: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if resolvedPlaylist != nil {
                        resolvedPlaylist = nil
                    } else {
                        mode = .chooser
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surfaceElevated))
            }
            .buttonStyle(.plain)
            .help("Back")

            VStack(alignment: .leading, spacing: 3) {
                Text("Playlists")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(playlistsHeaderSub)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            if case .connected(let name) = spotifyAuth.state {
                HStack(spacing: 8) {
                    Circle().fill(Theme.qualityCD).frame(width: 7, height: 7)
                    Text("Spotify connected · ")
                        .foregroundStyle(Theme.textSecondary)
                    + Text(name).foregroundStyle(Theme.textPrimary).fontWeight(.medium)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var playlistsHeaderSub: String {
        switch plState {
        case .resolved:
            return "Downloading a full playlist — every track at its highest available fidelity."
        case .grid, .resolving:
            return "Your Spotify library — pick a playlist to download in full."
        case .notConnected, .error:
            return "Connect your account, or paste a public Spotify playlist link."
        }
    }

    // ── Not connected ──────────────────────────────────────────────────────

    private var plNotConnectedState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.qualityCD.opacity(0.14)).frame(width: 96, height: 96).blur(radius: 22)
                Circle().fill(Theme.surfaceElevated).frame(width: 76, height: 76)
                Image(systemName: "music.note.list")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Theme.qualityCD)
            }
            .padding(.bottom, 26)

            Text("Connect your Spotify account")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Log in to list your own playlists here and download any of them in full lossless quality.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 470)
                .padding(.top, 10)
                .padding(.bottom, 28)

            Button {
                Task { await spotifyAuth.connect() }
            } label: {
                HStack(spacing: 9) {
                    if spotifyAuth.state == .connecting {
                        ProgressView().controlSize(.small).tint(Color(white: 0.05))
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(spotifyAuth.state == .connecting ? "Connecting…" : "Connect Spotify")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color(white: 0.05))
                .padding(.horizontal, 26).frame(height: 46)
                .background(Capsule().fill(Theme.qualityCD))
            }
            .buttonStyle(.plain)
            .disabled(spotifyAuth.state == .connecting)

            HStack(spacing: 14) {
                Rectangle().fill(Theme.divider).frame(height: 1)
                Text("or paste a public link")
                    .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.textTertiary).fixedSize()
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            .frame(width: 420)
            .padding(.top, 30).padding(.bottom, 18)

            plPasteBar.frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Public-link paste field for the not-connected fallback. Resolves via the
    /// no-auth embed path (`resolvePlaylist`), capped at 100 tracks.
    private var plPasteBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            TextField("open.spotify.com/playlist/…", text: $playlistURL)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .disabled(isResolvingPlaylist)
                .onSubmit(resolvePlaylist)
            Button(action: resolvePlaylist) {
                Text("Fetch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(Capsule().fill(Theme.surfaceElevated))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18).padding(.trailing, 7)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.divider, lineWidth: 1))
    }

    // ── Library grid ─────────────────────────────────────────────────────

    private var plGridState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Your playlists")
                        .font(.system(size: 11)).tracking(1.5).textCase(.uppercase)
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(spotifyAuth.playlists.count) from Spotify")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.bottom, 20)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 184), spacing: 20)],
                    spacing: 20
                ) {
                    if settings.showSpotifyLikedSongs {
                        playlistCard(SpotifyAuthController.likedSongsSummary)
                    }
                    ForEach(spotifyAuth.playlists) { playlistCard($0) }
                }
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 56)
        }
        .task {
            if spotifyAuth.playlists.isEmpty { await spotifyAuth.loadPlaylists() }
        }
    }

    private func playlistCard(_ p: SpotifyAuthController.PlaylistSummary) -> some View {
        SpotifyPlaylistCard(playlist: p) { openPlaylist(p) }
    }

    // ── Error ────────────────────────────────────────────────────────────

    private var plErrorState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.qualityLow.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Theme.qualityLow)
            }
            .padding(.bottom, 22)

            Text("Couldn't read that playlist")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(playlistError ?? "It may be private, or the link isn't a Spotify playlist.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 10)
                .padding(.bottom, 28)

            Button {
                playlistError = nil
                resolvedPlaylist = nil
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.left")
                    Text(spotifyAuth.isConnected ? "Back to playlists" : "Back")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24).frame(height: 44)
                .background(Capsule().fill(Theme.surfaceElevated))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // ── Resolved playlist ──────────────────────────────────────────────────

    private var plResolvedScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if spotifyAuth.isConnected {
                    Button { resolvedPlaylist = nil } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text("All playlists").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 14)
                }

                if playlistTruncated { plTruncatedWarning.padding(.bottom, 22) }

                if let p = resolvedPlaylist {
                    collectionView(
                        kind: "Playlist", title: p.title, meta: playlistMeta(p),
                        tracks: p.tracks, downloadAllLabel: "Download playlist"
                    ) {
                        rebuilder.rebuild(from: p, options: options)
                    }
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
    }

    private var plTruncatedWarning: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.qualityMid)
            Text("Showing the first \(SpotifyPlaylistService.trackCap) tracks. Spotify's public preview caps longer playlists — connect your account to fetch every track.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.qualityMid.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.qualityMid.opacity(0.30), lineWidth: 1))
    }

    private func playlistMeta(_ p: RemotePlaylist) -> String {
        var parts: [String] = []
        if let creator = p.creator { parts.append("by \(creator)") }
        parts.append("\(p.tracks.count) track\(p.tracks.count == 1 ? "" : "s")")
        let total = p.tracks.compactMap(\.durationSeconds).reduce(0, +)
        if total > 0 { parts.append("\(Int(total / 60)) min") }
        return parts.joined(separator: " · ")
    }

    private func openPlaylist(_ p: SpotifyAuthController.PlaylistSummary) {
        playlistError = nil
        resolvedPlaylist = nil
        playlistTruncated = false
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

    // MARK: - Sections

    /// `Binding<String>` over `options.quality`. Reads with a fallback to
    /// the format's first preset so the Picker always has a valid selection
    /// even before the user touches it (`options.quality` is `nil` for the
    /// default-Original case).
    private var qualityBinding: Binding<String> {
        Binding(
            get: {
                options.quality ?? options.format.qualities.first?.value ?? ""
            },
            set: { options.quality = $0 }
        )
    }

    /// Whether the pinned rebuild bar should show (any non-idle phase).
    private var showRebuildBar: Bool {
        if case .idle = rebuilder.phase { return false }
        return true
    }

    /// Compact rebuild progress/summary, pinned below the header (mirrors the
    /// docked Downloads drawer at the bottom). Per-track detail lives in that
    /// drawer; this bar is just the high-level status.
    @ViewBuilder
    private var rebuildTopBar: some View {
        Group {
            switch rebuilder.phase {
            case .idle:
                EmptyView()

            case .fetchingArtwork:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Preparing playlist…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    rebuildCancelButton
                }

            case .running(let current, let total):
                VStack(spacing: 8) {
                    HStack(spacing: Theme.Spacing.md) {
                        Text("Rebuilding playlist")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(current) of \(total) done")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        rebuildCancelButton
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.divider)
                            Capsule().fill(atAccent)
                                .frame(width: geo.size.width * CGFloat(current) / CGFloat(max(total, 1)))
                        }
                    }
                    .frame(height: 4)
                }

            case .finished(let summary):
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.qualityCD)
                    Text(summary.isResume ? "Playlist updated" : "Playlist rebuilt")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(rebuildSummaryLine(summary))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") { rebuilder.dismissSummary() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    private var rebuildCancelButton: some View {
        Button("Cancel") { rebuilder.cancel() }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
    }

    private func rebuildSummaryLine(_ summary: PlaylistRebuildCoordinator.Summary) -> String {
        var parts = ["\(summary.downloaded) downloaded",
                     "\(summary.reused.count) already in library"]
        if summary.alreadyInPlaylist > 0 { parts.append("\(summary.alreadyInPlaylist) already in playlist") }
        parts.append("\(summary.failures.count) failed")
        return "· " + parts.joined(separator: " · ")
    }

    private func jobStatusLabel(_ status: DownloadCoordinator.JobStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .downloading(let r, let t):
            if let t, t > 0 {
                let pct = Int((Double(r) / Double(t)) * 100)
                return "Downloading… \(pct)%"
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

    // MARK: - Actions

    private func resolve() {
        let trimmed = pasteURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed) else {
            error = "That URL doesn't look valid."
            return
        }
        // Spotify playlists are handled by the dedicated Playlists screen, not
        // Lucida (whose metadata endpoint fails on playlists). Redirect rather
        // than letting it error out.
        if SpotifyPlaylistService.playlistID(from: url) != nil {
            playlistURL = trimmed
            pasteURL = ""
            withAnimation(.easeInOut(duration: 0.15)) { mode = .playlists }
            resolvePlaylist()
            return
        }
        resolved = nil
        error = nil
        isWorking = true
        // Fresh paste — reset the options panel so the previous track's
        // choices don't silently leak into a new resolution.
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

    private func resolvePlaylist() {
        let trimmed = playlistURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed) else {
            playlistError = "That URL doesn't look valid."
            return
        }
        resolvedPlaylist = nil
        playlistTruncated = false
        playlistError = nil
        isResolvingPlaylist = true
        // Fresh paste — reset the options panel to the highest-quality default.
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

// MARK: - VPN advisory sheet

/// Compact floating advisory shown on first entry into the Downloads tab
/// each session. Styled as a standalone card — no FLSheet chrome — to match
/// the mockup: large shield + bold headline, centred body copy, checkbox.
private struct VpnNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Inverse of "Don't show again" — bound to `Settings.showVpnNotice`.
    @Binding var showVpnNoticeAgain: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Icon + headline ──────────────────────────────────────────
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Protect your connection!")
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.Spacing.xl)

            // ── Body ─────────────────────────────────────────────────────
            Text("Always use a VPN when downloading files, and only download files you already own or have a license to.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Text("Happy listening!")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, Theme.Spacing.lg)

            // ── Checkbox ─────────────────────────────────────────────────
            Toggle(isOn: Binding(
                get: { !showVpnNoticeAgain },
                set: { newVal in
                    showVpnNoticeAgain = !newVal
                    if newVal { dismiss() }
                }
            )) {
                Text("Don't show this again")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .padding(.top, Theme.Spacing.xl)

            // ── Got it ───────────────────────────────────────────────────
            Button("Got it") { dismiss() }
                .buttonStyle(PillButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, Theme.Spacing.lg)
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: 400)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)
    }
}

/// A Spotify playlist tile in the Downloads grid. Own view so it can carry
/// the same hover rise + cover glow as library cards.
private struct SpotifyPlaylistCard: View {
    let playlist: SpotifyAuthController.PlaylistSummary
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
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
                // non-square Spotify mosaics/photos are cropped instead of
                // widening the card off-grid.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(SquareSlot())
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(0.4), radius: 11, x: 0, y: 8)
                .coverHoverHighlight(isHovering: isHovering, cornerRadius: 9)

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        // Always reserve two lines so 1- and 2-line titles
                        // produce identical card heights across the grid.
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(playlist.trackCount < 0 ? "your saved tracks" : "\(playlist.owner ?? "you") · \(playlist.trackCount) tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 2).padding(.bottom, 2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .cardHoverLift(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }
}

/// Fixes content to a square of the proposed width, centering and clipping
/// whatever is inside.
private struct SquareSlot: ViewModifier {
    func body(content: Content) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipped()
    }
}
