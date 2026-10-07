import SwiftUI

struct FloatingPlayerBar: View {
    @Environment(PlayerState.self)       private var player
    @Environment(PlaylistStore.self)     private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(LibraryStore.self)      private var library
    @Environment(NavigationRouter.self)  private var router
    @Environment(CastManager.self)       private var cast

    @Environment(\.colorScheme) private var colorScheme
    @State private var wash: NSImage?
    @State private var contentWidth: CGFloat = 0

    /// Half the transport row (five buttons and their gaps), which sits
    /// centered on the bar regardless of what's beside it.
    private static let transportHalfWidth: CGFloat = 115

    /// Room for the title, artist and badge: from the cover to a gap short
    /// of the centered transport controls, so they never run underneath.
    private var trackTextMaxWidth: CGFloat {
        guard contentWidth > 0 else { return 200 }
        let coverAndGap: CGFloat = 48 + Theme.Spacing.sm
        let room = contentWidth / 2 - Self.transportHalfWidth - 20 - coverAndGap
        return min(340, max(60, room))
    }

    var body: some View {
        if let track = player.currentTrack {
            playerContent
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .background { glass(for: track) }
                .task(id: track.id) { await loadWash(for: track) }
        }
    }

    // MARK: - Glass

    private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    /// Frosted glass over the page, with a faint wash of the playing cover
    /// behind the track info, a lit top edge and a soft drop shadow.
    private func glass(for track: Track) -> some View {
        let light = colorScheme == .light
        return Self.shape
            .fill(.ultraThinMaterial)
            .overlay(Self.shape.fill(light ? Color(white: 1).opacity(0.5) : Color(white: 0.08).opacity(0.46)))
            .overlay {
                // Sized and placed inside the bar's own bounds, then clipped
                // to its shape, so the glow can't spill onto the page.
                GeometryReader { geo in
                    if let wash {
                        Image(nsImage: wash)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 420, height: max(geo.size.height * 2, 220))
                            .saturation(1.6)
                            .opacity(light ? 0.22 : 0.38)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing))
                            .position(x: 170, y: geo.size.height / 2)
                            .transition(.opacity)
                    }
                }
                .clipShape(Self.shape)
                .allowsHitTesting(false)
            }
            .overlay(
                Self.shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(light ? 0.8 : 0.16), Theme.textPrimary.opacity(light ? 0.08 : 0.1)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(light ? 0.16 : 0.55), radius: 30, y: 16)
    }

    private func loadWash(for track: Track) async {
        guard let data = track.artwork, !data.isEmpty else {
            wash = nil
            return
        }
        let id = "queue-hero:\(ArtworkImageCache.contentID(for: data))"
        if let hit = BlurredArtworkCache.shared.cached(id: id) {
            wash = hit
            return
        }
        let box = await BlurredArtworkCache.shared.image(for: data, id: id)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.35)) { wash = box.image }
    }

    private var playerContent: some View {
        VStack(spacing: 4) {
            ZStack {
                // Center: transport controls (centered to full bar width)
                transportControls

                // Left: track info / Right: queue toggle + volume pinned to edges
                HStack(spacing: Theme.Spacing.sm) {
                    trackInfo
                    Spacer(minLength: 0)
                    addToPlaylistButton
                    queueToggleButton
                    SpeakerPickerButton()
                    VolumeSliderView()
                }
            }
            .frame(height: 50)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }

            SeekBarView(prominent: true)
        }
    }

    // MARK: - Track Info

    @ViewBuilder
    private var trackInfo: some View {
        if let track = player.currentTrack {
            HStack(spacing: Theme.Spacing.sm) {
                ArtworkView(data: track.artwork, size: 48)

                VStack(alignment: .leading, spacing: 1) {
                    // The badge always shows in full beside the title; a
                    // title too long for what's left scrolls instead.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(track.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                            PlayerQualityBadge(track: track)
                        }
                        HStack(spacing: 6) {
                            MarqueeText(
                                text: track.title,
                                font: .system(size: 13),
                                weight: .medium,
                                speed: 24,
                                pause: 2
                            )
                            PlayerQualityBadge(track: track)
                        }
                    }
                    if let artist = ArtistResolver.displayString(track.artist) {
                        Text(artist)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if let speaker = cast.activeSpeaker {
                        Label("Playing on \(speaker.name)",
                              systemImage: speaker.isAirPlay ? "airplay.audio" : "hifispeaker.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: trackTextMaxWidth, alignment: .leading)
            }
            .flContextMenu {
                FLContextMenuItem.button("View Album", systemImage: "square.grid.2x2") {
                    if let albumID = library.album(for: track)?.id {
                        router.navigateToAlbum(id: albumID)
                    }
                }
                let artistItems = artistContextMenuItems(
                    credit: track.artist ?? track.albumArtist,
                    library: library,
                    router: router
                )
                if !artistItems.isEmpty {
                    FLContextMenuItem.divider
                    artistItems
                }
            }
        }
    }

    // MARK: - Add to Playlist

    private var addToPlaylistButton: some View {
        Button {
            FLContextMenuWindow.present(items: buildAddToPlaylistItems(), at: NSEvent.mouseLocation)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(GlassIconButtonStyle())
        .frame(width: 26, height: 26)
        .help("Add to playlist")
    }

    private func buildAddToPlaylistItems() -> [FLContextMenuItem] {
        var items: [FLContextMenuItem] = []
        if playlistStore.playlists.isEmpty {
            items.append(.label("No playlists yet"))
        } else {
            for playlist in playlistStore.playlists {
                items.append(.button(playlist.name) { addCurrentTrack(to: playlist.id) })
            }
            items.append(.divider)
        }
        items.append(.textField("New playlist name…", systemImage: "plus") { name in
            guard let track = player.currentTrack else { return }
            playlistAddCoordinator.createPlaylistAndAdd(
                name: name,
                tracks: [track],
                rootURL: library.rootURL,
                store: playlistStore
            )
        })
        return items
    }

    private func addCurrentTrack(to playlistID: UUID) {
        guard let track = player.currentTrack,
              let playlist = playlistStore.playlists.first(where: { $0.id == playlistID }) else { return }
        playlistAddCoordinator.request(
            tracks: [track],
            playlistID: playlistID,
            playlistName: playlist.name,
            rootURL: library.rootURL,
            store: playlistStore
        )
    }

    // MARK: - Queue Toggle

    private var queueToggleButton: some View {
        Button {
            withAnimation(QueuePanelView.motion) {
                player.isQueueVisible.toggle()
            }
        } label: {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(GlassIconButtonStyle(isOn: player.isQueueVisible))
        .help(player.isQueueVisible ? "Hide queue" : "Show queue")
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GlassIconButtonStyle(isOn: player.isShuffleEnabled, showsDot: true))
            .help(player.isShuffleEnabled ? "Shuffle on" : "Shuffle off")

            Button { player.engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))

            Button { player.engine.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .medium))
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))

            Button {
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GlassIconButtonStyle(isOn: player.repeatMode != .off, showsDot: true))
            .help(repeatHelp)
        }
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }
}

// MARK: - Pieces

/// The player bar's icon buttons: tertiary at rest, primary on hover, a
/// faint circle under the pointer, and a small press. `isOn` lights a toggle
/// in the accent, with a dot under it when `showsDot` is set; `isProminent`
/// is for the transport buttons, always drawn in the primary ink.
struct GlassIconButtonStyle: ButtonStyle {
    var isOn = false
    var showsDot = false
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        GlassIconButton(configuration: configuration, isOn: isOn, showsDot: showsDot, isProminent: isProminent)
    }

    private struct GlassIconButton: View {
        let configuration: Configuration
        let isOn: Bool
        let showsDot: Bool
        let isProminent: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isOn ? Theme.accent : (isProminent || isHovering ? Theme.textPrimary : Theme.textTertiary))
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering ? 0.07 : 0)))
                .overlay(alignment: .bottom) {
                    if showsDot && isOn {
                        Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: -1)
                    }
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

/// The playing track's fidelity, tiny, beside its title: "24/96" in the
/// tier's color, or the tier name when the file carries no rate.
private struct PlayerQualityBadge: View {
    let track: Track

    var body: some View {
        let quality = AudioQuality.of(track)
        let detail = FormatUtils.formatSampleRate(track.sampleRate, bitDepth: track.bitDepth)
        Text(detail ?? quality.label)
            .font(.system(size: 9.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(quality.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(quality.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .help(FormatUtils.techSpec(for: track).map { "\(quality.label) · \($0)" } ?? quality.label)
    }
}
