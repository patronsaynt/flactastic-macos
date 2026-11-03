import SwiftUI
import AppKit

/// The mini player in the menu bar icon's popover (`MenuBarPlayerController`),
/// for quick control from any app: what's on and its quality, a seek line
/// that runs on into the next few tracks, the transport (shuffle and repeat included), volume and
/// speaker, and a queue drawer that stays open or closed as it was left.
/// Drawn in the floating player bar's own glass and buttons, and bound to the
/// shared `PlayerState`, so it and the main window always agree.
struct MenuBarPlayerView: View {
    @Environment(PlayerState.self) private var player

    @AppStorage("flactastic.menuBar.queueOpen") private var isQueueOpen = false

    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let track = player.currentTrack {
                    header(track)
                    RoadAheadBar()
                    PlayerTransportControls()
                        .frame(maxWidth: .infinity)
                } else {
                    emptyState
                }
                utilityRow
            }
            .padding(16)

            if isQueueOpen, player.currentTrack != nil {
                Rectangle().fill(Theme.textPrimary.opacity(0.08)).frame(height: 1)
                drawer
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .background { PlayerGlass(track: player.currentTrack, cornerRadius: 0, isFloating: false).ignoresSafeArea() }
    }

    // MARK: - What's on

    private func header(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(data: track.artwork, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                // The badge always shows in full beside the title; a title
                // too long for what's left scrolls instead.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                        PlayerQualityBadge(track: track)
                    }
                    HStack(spacing: 6) {
                        MarqueeText(text: track.title, font: .system(size: 13.5), weight: .semibold, speed: 24, pause: 2)
                        PlayerQualityBadge(track: track)
                    }
                }
                if let artist = ArtistResolver.displayString(track.artist) {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let album = track.album {
                    Text(album)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 56, height: 56)
                .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing playing")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Open FLACtastic to pick something.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Volume, speaker, app, queue

    private var utilityRow: some View {
        HStack(spacing: 6) {
            if player.currentTrack != nil {
                VolumeSliderView(width: 96)
            }
            Spacer(minLength: 0)
            if player.currentTrack != nil {
                SpeakerPickerButton()
            }
            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Open FLACtastic")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Quit FLACtastic")
            if player.currentTrack != nil {
                Button {
                    withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)) { isQueueOpen.toggle() }
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(GlassIconButtonStyle(isOn: isQueueOpen))
                .help(isQueueOpen ? "Hide queue" : "Show queue")
            }
        }
    }

    // MARK: - Queue drawer

    /// Next Up, editable as in the queue panel; as tall as its tracks, up
    /// to a scroll.
    @ViewBuilder
    private var drawer: some View {
        let count = player.upcoming.count
        if count == 0 {
            Text("Nothing up next")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        } else {
            ScrollView {
                QueueUpNextList(rowWidth: Self.width - 24, compact: true) { track, engineIndex in
                    [
                        .button("Play Now", systemImage: "play.fill") { player.jumpTo(index: engineIndex) },
                        .button("Remove from Queue", systemImage: "minus.circle") { player.removeFromQueue(at: engineIndex) },
                    ]
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(count) * 46 + 60, 320))
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the first app window forward, skipping the popover's own
        // window, which can't become main.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

// MARK: - The road ahead

/// The seek line, carried on past the song: this track's scrubbable stretch,
/// then the next three as short segments. Hover one to name it; click it to
/// play it. Below, the times, or the hovered track.
private struct RoadAheadBar: View {
    @Environment(PlayerState.self) private var player
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var hovered: Int?

    private static let gap: CGFloat = 4
    private static let thumb: CGFloat = 12

    var body: some View {
        let ahead = Array(player.upcoming.prefix(3))
        let duration = player.duration ?? 1
        let time = isDragging ? dragValue : player.currentTime

        VStack(spacing: 6) {
            GeometryReader { geo in
                let aheadWidth = ahead.isEmpty ? 0 : geo.size.width * 0.34
                let nowWidth = geo.size.width - aheadWidth - (ahead.isEmpty ? 0 : Self.gap)
                let segment = ahead.isEmpty ? 0 : (aheadWidth - Self.gap * CGFloat(ahead.count - 1)) / CGFloat(ahead.count)
                HStack(spacing: Self.gap) {
                    nowSegment(width: nowWidth, progress: duration > 0 ? time / duration : 0, duration: duration)
                    ForEach(Array(ahead.enumerated()), id: \.element.track.id) { offset, item in
                        let isHovered = hovered == offset
                        Capsule()
                            .fill(Theme.textPrimary.opacity(isHovered ? 0.4 : 0.14 - Double(offset) * 0.03))
                            .frame(width: segment, height: isHovered ? 7 : 5)
                            .frame(height: Self.thumb)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hovered = offset } else if hovered == offset { hovered = nil }
                            }
                            .onTapGesture { player.jumpTo(index: item.engineIndex) }
                            .accessibilityElement()
                            .accessibilityLabel("Play \(item.track.title)")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovered)
            }
            .frame(height: Self.thumb)

            caption(ahead: ahead, time: time, duration: duration)
                .frame(height: 15)
        }
    }

    private func nowSegment(width: CGFloat, progress: Double, duration: Double) -> some View {
        let filled = max(0, min(CGFloat(progress) * width, width))
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.textPrimary.opacity(0.14)).frame(height: 5)
            Capsule().fill(Theme.accent).frame(width: filled, height: 5)
            Circle()
                .fill(Theme.accent)
                .frame(width: Self.thumb, height: Self.thumb)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .offset(x: max(0, min(filled - Self.thumb / 2, width - Self.thumb)))
        }
        .frame(width: width, height: Self.thumb)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    dragValue = max(0, min(value.location.x / width, 1)) * duration
                }
                .onEnded { value in
                    player.engine.seek(to: max(0, min(value.location.x / width, 1)) * duration)
                    isDragging = false
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(FormatUtils.formatDuration(player.currentTime))
    }

    /// The times; while a segment ahead is hovered, which track it is.
    @ViewBuilder
    private func caption(ahead: [(track: Track, engineIndex: Int)], time: Double, duration: Double) -> some View {
        if let hovered, hovered < ahead.count {
            let track = ahead[hovered].track
            HStack(spacing: 5) {
                Text(["Next", "After that", "Then"][hovered])
                    .foregroundStyle(Theme.textTertiary)
                Text(track.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                if let artist = ArtistResolver.displayString(track.artist) {
                    Text("— \(artist)")
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
        } else {
            HStack {
                Text(FormatUtils.formatDuration(time))
                Spacer()
                Text("-\(FormatUtils.formatDuration(max(0, duration - time)))")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .monospacedDigit()
        }
    }
}
