import SwiftUI

/// The player in compact form, for pages that dock it in a column of their
/// own instead of floating the main bar over their content (the Playlists
/// page, at the foot of its playlist list). Same controls as the floating
/// bar: track info with its quality badge, add to playlist, the queue, the
/// seek bar, transport, speaker and volume.
struct MiniPlayerView: View {
    @Environment(PlayerState.self) private var player
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationRouter.self) private var router
    @Environment(CastManager.self) private var cast

    var body: some View {
        if let track = player.currentTrack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    trackInfo(track)
                    Spacer(minLength: 4)
                    Button {
                        FLContextMenuWindow.present(items: addToPlaylistItems(track), at: NSEvent.mouseLocation)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .help("Add to playlist")
                    Button {
                        withAnimation(QueuePanelView.motion) { player.isQueueVisible.toggle() }
                    } label: {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(GlassIconButtonStyle(isOn: player.isQueueVisible))
                    .help(player.isQueueVisible ? "Hide queue" : "Show queue")
                }

                SeekBarView()

                HStack(spacing: 4) {
                    PlayerTransportControls(compact: true)

                    Spacer(minLength: 6)
                    SpeakerPickerButton()
                    VolumeSliderView()
                }
            }
            .padding(14)
            .background(Theme.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(0.08), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .offset(y: 12)))
        }
    }

    private func trackInfo(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(data: track.artwork, size: 48, id: "track:\(track.id)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    PlayerQualityBadge(track: track)
                }
                if let artist = ArtistResolver.displayString(track.artist) {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let speaker = cast.activeSpeaker {
                    Label("Playing on \(speaker.name)",
                          systemImage: speaker.isAirPlay ? "airplay.audio" : "hifispeaker.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .flContextMenu {
            var items: [FLContextMenuItem] = []
            if let albumID = library.album(for: track)?.id {
                items.append(.button("View Album", systemImage: "square.grid.2x2") {
                    router.navigateToAlbum(id: albumID)
                })
            }
            let artistItems = artistContextMenuItems(credit: track.artist ?? track.albumArtist, library: library, router: router)
            if !artistItems.isEmpty {
                if !items.isEmpty { items.append(.divider) }
                items.append(contentsOf: artistItems)
            }
            return items
        }
    }

    /// The same menu as the floating bar's + button.
    private func addToPlaylistItems(_ track: Track) -> [FLContextMenuItem] {
        FloatingPlayerBar.addToPlaylistItems(for: track, playlistStore: playlistStore,
                                             coordinator: playlistAddCoordinator, rootURL: library.rootURL)
    }
}
