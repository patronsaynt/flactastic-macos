import SwiftUI

/// The queue: a full-height panel flush with the window's right edge. The
/// playing cover fills its top as a blurred backdrop behind the now-playing
/// details; below it, Next Up is grouped by where each run of tracks came
/// from (queued by the user, or the album or playlist playback started from).
struct QueuePanelView: View {
    @Environment(PlayerState.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationRouter.self) private var router
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(PlaylistAddCoordinator.self) private var playlistAddCoordinator
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 400

    @State private var editingTrack: Track? = nil
    @State private var draggingTrackID: UUID? = nil
    @State private var dropTargetTrackID: UUID? = nil

    private var menus: LibraryMenus {
        LibraryMenus(player: player, library: library, playlistStore: playlistStore,
                     playlistAdd: playlistAddCoordinator, router: router)
    }

    /// All upcoming entries (engine indices > currentIndex).
    private var upcoming: [(track: Track, engineIndex: Int)] {
        let q = player.queue
        let start = player.currentIndex + 1
        guard start < q.count else { return [] }
        return (start..<q.count).map { (q[$0], $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            QueueHero(track: player.currentTrack, isPlaying: player.isPlaying) {
                close()
            }
            .flContextMenu(priority: 1) {
                player.currentTrack.map { nowPlayingMenu(for: $0) } ?? []
            }

            if upcoming.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.textPrimary.opacity(0.1)).frame(width: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(colorScheme == .light ? 0.15 : 0.55), radius: 40, x: -16)
        .sheet(item: $editingTrack) { track in
            TrackMetadataEditorView(track: track)
                .environment(library)
        }
    }

    private func close() {
        withAnimation(Self.motion) { player.isQueueVisible = false }
    }

    /// The panel's slide, shared with the player bar making room for it.
    static let motion = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)

    // MARK: - Menus

    private func nowPlayingMenu(for track: Track) -> [FLContextMenuItem] {
        var items: [FLContextMenuItem] = [menus.addToPlaylist([track])]
        if let albumID = library.album(for: track)?.id {
            items.append(.divider)
            items.append(.button("View Album", systemImage: "square.grid.2x2") {
                router.navigateToAlbum(id: albumID)
            })
        }
        let artists = artistContextMenuItems(credit: track.artist ?? track.albumArtist, library: library, router: router)
        if !artists.isEmpty {
            items.append(.divider)
            items.append(contentsOf: artists)
        }
        return items
    }

    private func upcomingMenu(track: Track, engineIndex: Int) -> [FLContextMenuItem] {
        menus.track(
            track,
            extra: [.button("Remove from Queue", systemImage: "minus.circle") {
                player.removeFromQueue(at: engineIndex)
            }],
            edit: { editingTrack = track }
        )
    }

    // MARK: - List

    private var queueList: some View {
        let items = upcoming
        let remaining = items.reduce(0) { $0 + ($1.track.duration ?? 0) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Next up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(FormatUtils.coarseDuration(remaining)) left")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                    Button("Clear") { player.clearUpcoming() }
                        .buttonStyle(QuietTextButtonStyle())
                        .help("Remove everything after the current track")
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

                // Tracks you queued sit together at the top under "Queued by
                // you". One dragged further down, among the source's tracks,
                // keeps an "Added" tag instead, the way Spotify marks them.
                let queuedRun = items.prefix { player.isUserQueued($0.track) }.count
                ForEach(Array(items.enumerated()), id: \.element.track.id) { offset, item in
                    if offset == 0 && queuedRun > 0 {
                        groupLabel(userQueued: true)
                    }
                    if offset == queuedRun {
                        groupLabel(userQueued: false)
                    }
                    draggableRow(item: item, isAdded: offset >= queuedRun && player.isUserQueued(item.track))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
    }

    /// Where the following run of tracks came from.
    @ViewBuilder
    private func groupLabel(userQueued: Bool) -> some View {
        let label: Text? = userQueued
            ? Text("Queued by you")
            : player.playbackSource.map { Text("Playing from ") + Text($0).fontWeight(.semibold).foregroundColor(Theme.textSecondary) }
        if let label {
            label
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func draggableRow(item: (track: Track, engineIndex: Int), isAdded: Bool) -> some View {
        let trackID = item.track.id
        let isDropTarget = dropTargetTrackID == trackID && draggingTrackID != trackID

        QueueTrackRow(track: item.track, isAdded: isAdded) {
            player.removeFromQueue(at: item.engineIndex)
        }
        .opacity(draggingTrackID == trackID ? 0.35 : 1.0)
        .overlay(alignment: .top) {
            // Insertion bar shown above the hovered row.
            if isDropTarget {
                Capsule().fill(Theme.accent).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            player.jumpTo(index: item.engineIndex)
        }
        .flContextMenu(priority: 1) { upcomingMenu(track: item.track, engineIndex: item.engineIndex) }
        .draggable(trackID.uuidString) {
            QueueTrackRow(track: item.track, isAdded: isAdded, onRemove: nil)
                .frame(width: Self.width - 40)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                .onAppear { draggingTrackID = trackID }
                .onDisappear {
                    draggingTrackID = nil
                    dropTargetTrackID = nil
                }
        }
        .dropDestination(for: String.self) { items, _ in
            dropTargetTrackID = nil
            draggingTrackID = nil
            guard let s = items.first, let srcID = UUID(uuidString: s) else {
                return false
            }
            player.moveTrack(withID: srcID, before: trackID)
            return true
        } isTargeted: { hovering in
            dropTargetTrackID = hovering ? trackID : (dropTargetTrackID == trackID ? nil : dropTargetTrackID)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing up next")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Right-click an album or track and choose Play Next or Add to Queue.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hero

/// The top of the panel: the playing cover blurred past detail, with the
/// cover itself, its title, artist and quality over it.
private struct QueueHero: View {
    let track: Track?
    let isPlaying: Bool
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var backdrop: NSImage?
    @State private var settled = false

    var body: some View {
        // The content sets the size and sits at the top; the backdrop is a
        // background, so a cover taller than the hero can't grow it and
        // push the top out of view.
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                Spacer()
                SheetCloseButton(label: "Close queue", handlesEscape: false, action: onClose)
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .padding(.top, 16)

            if let track {
                nowPlaying(track)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .opacity(settled ? 1 : 0)
                    .offset(y: settled ? 0 : 16)
            }
        }
        .foregroundStyle(track == nil ? Theme.textPrimary : .white)
        // Over the dark backdrop everything reads as dark mode.
        .environment(\.colorScheme, track == nil ? colorScheme : .dark)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: track == nil ? 64 : 250, alignment: .top)
        .background {
            if track != nil {
                backdropLayer
                    .overlay(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.4), .init(color: Theme.surface, location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
        }
        .clipped()
        .task(id: track?.id) { await loadBackdrop() }
        .onAppear {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7).delay(0.12)) { settled = true }
        }
    }

    /// Black, with the blurred cover filling it. The image is an overlay on
    /// the color so it takes the hero's size instead of its own.
    private var backdropLayer: some View {
        Color.black
            .overlay {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .saturation(1.4)
                        .brightness(-0.22)
                        .scaleEffect(settled ? 1 : 1.15)
                        .transition(.opacity)
                }
            }
            .clipped()
    }

    private func nowPlaying(_ track: Track) -> some View {
        HStack(alignment: .bottom, spacing: 18) {
            ArtworkView(data: track.artwork, size: 132, id: "track:\(track.id)")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    EqualizerBars(isAnimating: isPlaying)
                    Text("Now playing")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))

                Text(track.title)
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(-0.7)
                    .lineLimit(2)
                    .padding(.top, 8)
                if let artist = ArtistResolver.displayString(track.artist ?? track.albumArtist) {
                    Text(artist)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                if let spec = FormatUtils.techSpec(for: track) {
                    let quality = AudioQuality.of(track)
                    Text(spec)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(quality.color)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(quality.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func loadBackdrop() async {
        guard let data = track?.artwork, !data.isEmpty else {
            backdrop = nil
            return
        }
        let id = "queue-hero:\(ArtworkImageCache.contentID(for: data))"
        if let hit = BlurredArtworkCache.shared.cached(id: id) {
            backdrop = hit
            return
        }
        let box = await BlurredArtworkCache.shared.image(for: data, id: id)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.35)) { backdrop = box.image }
    }
}

/// Three bars that bounce while playing and rest when paused.
private struct EqualizerBars: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = isAnimating ? (sin(t * 6 + Double(i) * 1.9) + 1) / 2 : 0.25
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: 3 + 9 * phase)
                }
            }
            .frame(height: 12, alignment: .bottom)
        }
    }
}

// MARK: - Row

private struct QueueTrackRow: View {
    let track: Track
    /// Shown as an ✕ on hover; nil for the drag preview.
    /// Queued by the user but sitting among the source's tracks.
    var isAdded = false
    let onRemove: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(data: track.artwork, size: 44, id: "track:\(track.id)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isAdded {
                        Text("Added")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Theme.textPrimary.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
                            .help("Added to the queue by you")
                    }
                }
                if let artist = ArtistResolver.displayString(track.artist) {
                    Text(artist)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            ZStack(alignment: .trailing) {
                Text(FormatUtils.formatDuration(track.duration))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .opacity(isHovered && onRemove != nil ? 0 : 1)
                if isHovered, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Theme.textPrimary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                }
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.textPrimary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Pull tab

/// The closed queue's handle: a thin grabber on the window's right edge
/// that grows on hover and names what's queued.
struct QueuePullTab: View {
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        // Only the edge strip takes the pointer; the label floats beside it
        // without blocking the page underneath.
        Button(action: action) {
            Capsule()
                .fill(isHovering ? Theme.textPrimary : Theme.textPrimary.opacity(0.16))
                .frame(width: 5, height: isHovering ? 84 : 56)
                .padding(.trailing, 6)
                .frame(width: 24, height: 120, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Text(count > 0 ? "Queue · \(count)" : "Queue")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
                .opacity(isHovering ? 1 : 0)
                .offset(x: isHovering ? -26 : -18)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: isHovering)
        .help("Show queue")
        .accessibilityLabel(count > 0 ? "Show queue, \(count) up next" : "Show queue")
    }
}
