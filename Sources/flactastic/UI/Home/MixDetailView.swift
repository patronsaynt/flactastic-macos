import SwiftUI

/// One of Home's generated mixes, opened like a playlist and drawn exactly
/// as the playlist page is: a hero on a blurred wash of its cover, then its
/// tracks. Each track's menu adds "More Like This" and "Doesn't Fit This
/// Mix"; both rebuild the mix, and this page shows the new one.
struct MixDetailView: View {
    let mix: HomeFeed.Mix
    /// The cover as Home renders it (artist photo on the mix's colour).
    let cover: Data?
    /// The playlist it was saved as this session, if it was.
    let savedPlaylistID: UUID?
    let onBack: () -> Void
    let onPlay: (_ index: Int, _ shuffle: Bool) -> Void
    let onSave: () -> Void
    /// Draws the mix again, keeping its ratings.
    let onReroll: () -> Void

    @Environment(\.topBarInset) private var topBarInset
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @Environment(NavigationRouter.self) private var router
    @Environment(PlaylistAddCoordinator.self) private var playlistAdd
    @Environment(Settings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasEntered = false
    @State private var editingTrack: Track?
    @State private var removalRequest: LibraryRemovalRequest?
    @State private var backdrop: NSImage?

    private static let heroHeight: CGFloat = 540

    private var isLight: Bool { colorScheme == .light }
    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }
    private var ink: Color { isLight ? Theme.textPrimary : .white }
    private var inkSecondary: Color { isLight ? Color(white: 0.28) : .white.opacity(0.85) }
    private var arrive: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.7) }
    private var coverID: String { "mix:\(mix.id):\(cover?.count ?? 0)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                Group {
                    FLTrackListHeader(showDragHandle: false)
                    trackList
                }
                .padding(.horizontal, collectionGutter)
                .padding(.top, 8)
                .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.8))
            }
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
        .blur(radius: hasEntered || calmMotion ? 0 : 28)
        .opacity(hasEntered ? 1 : 0)
        .background(Theme.background)
        .onAppear {
            withAnimation(calmMotion
                          ? .easeOut(duration: 0.3)
                          : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1)) {
                hasEntered = true
            }
        }
        .onExitCommand(perform: onBack)
        .task(id: coverID) {
            let id = "playlist-stage:\(coverID)"
            backdrop = BlurredArtworkCache.shared.cached(id: id)
            if backdrop == nil {
                backdrop = await BlurredArtworkCache.shared.image(for: cover, id: id).image
            }
        }
        .sheet(item: $editingTrack) { track in
            TrackMetadataEditorView(track: track)
                .environment(library)
        }
        .removeFromLibraryConfirmation($removalRequest, library: library)
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            backdropLayer
                .scaleEffect(hasEntered || calmMotion ? 1 : 1.14)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.9), value: hasEntered)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(isLight ? 0.12 : 0.35), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: Theme.background.opacity(0.25), location: 0.6),
                    .init(color: Theme.background, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 40) {
                ArtworkView(data: cover, size: 300, id: coverID)
                    .shadow(color: .black.opacity(isLight ? 0.25 : 0.6), radius: 30, y: 24)
                    .flContextMenu { playbackContextMenuItems(for: mix.tracks, player: player) }
                    .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
                    .opacity(hasEntered ? 1 : 0)
                    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(calmMotion ? 0 : 0.22), value: hasEntered)

                heroDetails
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, collectionGutter)
            .padding(.bottom, 44)
        }
        .frame(height: Self.heroHeight + topBarInset)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            HeroBackButton(action: onBack)
                .help("Back to Home")
                .padding(.leading, collectionGutter)
                .padding(.top, Theme.Spacing.xl + topBarInset)
                .opacity(hasEntered ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(calmMotion ? 0 : 0.15), value: hasEntered)
        }
    }

    private var backdropLayer: some View {
        Color.clear
            .overlay {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.2)
                        .saturation(1.4)
                        .brightness(isLight ? 0.18 : -0.2)
                } else {
                    Theme.surface
                }
            }
            .clipped()
            .allowsHitTesting(false)
    }

    private var heroDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mix.name)
                .lineLimit(2)
                .minimumScaleFactor(0.45)
                .font(.system(size: 80, weight: .heavy))
                .tracking(-3)
                .foregroundStyle(ink)
                .offset(y: hasEntered || calmMotion ? 0 : 160)
                .padding(.bottom, 6)
                .clipped()
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.95).delay(calmMotion ? 0 : 0.32), value: hasEntered)

            Text("\(mix.featuring). Built from your library for today.")
                .font(.system(size: 16))
                .foregroundStyle(inkSecondary)
                .lineLimit(2)
                .padding(.top, 8)
                .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

            Text("Mix · " + FormatUtils.playlistSummary(
                trackCount: mix.tracks.count,
                duration: mix.tracks.reduce(0) { $0 + ($1.duration ?? 0) }
            ))
            .font(.system(size: 14))
            .foregroundStyle(inkSecondary)
            .padding(.top, 10)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

            QualityMixBar(tracks: mix.tracks, width: 220, ink: inkSecondary)
                .padding(.top, 10)
                .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

            HStack(spacing: Theme.Spacing.md) {
                Button { onPlay(0, false) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(HeroPillStyle(kind: .primary, ink: ink, isLight: isLight))
                Button { onPlay(0, true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                if let saved = savedPlaylistID, playlistStore.playlists.contains(where: { $0.id == saved }) {
                    Button { router.navigateToPlaylist(id: saved) } label: { Image(systemName: "music.note.list") }
                        .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                        .help("Open saved playlist")
                        .accessibilityLabel("Open saved playlist")
                } else {
                    Button(action: onSave) { Image(systemName: "plus.square.on.square") }
                        .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                        .help("Save as a playlist in your library")
                        .accessibilityLabel("Save playlist to library")
                }
                Button(action: onReroll) { Image(systemName: "dice") }
                    .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                    .help("Reroll: draw a new set of tracks for this mix. Your ratings still apply.")
                    .accessibilityLabel("Reroll mix")
            }
            .padding(.top, 24)
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.62))
        }
    }

    // MARK: - Tracks

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mix.tracks.enumerated()), id: \.element.id) { index, track in
                let isCurrent = player.currentTrack?.id == track.id
                TrackRow(track: track, isPlaying: isCurrent, displayNumber: index + 1,
                         showDragHandle: false, showAlbumArt: true)
                    .flRowStyle(fill: isCurrent ? Theme.surfaceElevated : nil)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onPlay(index, false) }
                    .flContextMenu { menu(for: track) }
            }
        }
    }

    private func menu(for track: Track) -> [FLContextMenuItem] {
        let menus = LibraryMenus(player: player, library: library, playlistStore: playlistStore,
                                 playlistAdd: playlistAdd, router: router)
        return menus.track(
            track,
            extra: mixFeedbackItems(for: track, in: mix, player: player, library: library, settings: settings),
            edit: { editingTrack = track },
            remove: { removalRequest = LibraryRemovalRequest(title: track.title, tracks: [track]) }
        )
    }
}
