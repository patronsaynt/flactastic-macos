import SwiftUI

struct FloatingPlayerBar: View {
    @Environment(PlayerState.self)       private var player
    @Environment(Settings.self)          private var settings
    @Environment(PlaylistStore.self)     private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(LibraryStore.self)      private var library
    @Environment(NavigationRouter.self)  private var router
    @Environment(CastManager.self)       private var cast

    var body: some View {
        if player.currentTrack != nil {
            playerContent
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.surface)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                )
        }
    }

    private var playerContent: some View {
        VStack(spacing: Theme.Spacing.xs) {
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
                    Text(track.title)
                        .font(.system(size: 13))
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
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
                .frame(maxWidth: 160, alignment: .leading)
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
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            withAnimation(.easeInOut(duration: 0.28)) {
                player.isQueueVisible.toggle()
            }
        } label: {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(player.isQueueVisible ? Theme.accent : Theme.textTertiary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(player.isShuffleEnabled ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)

            Button { player.engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { player.engine.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 50, height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 13))
                    .foregroundStyle(player.repeatMode != .off ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }
}
