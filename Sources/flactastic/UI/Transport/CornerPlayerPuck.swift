import SwiftUI

/// The player: a small glass puck in the corner (cover, title, previous,
/// play, next, queue, a progress line along its lip). Clicking it opens the
/// same glass into the full floating player bar in two moves, width first,
/// then height; clicking again closes it in exact reverse.
///
/// Everything sits in one clipped container the size of the glass. The
/// cover, title and queue button are single views drawn at the bar's size,
/// scaled and placed for the puck, and grow into place as the height opens.
/// The puck's own transport fades out as it widens; the bar's other parts
/// are always laid out underneath and fade (and unblur) in as it rises.
/// Nothing is inserted or removed mid-animation.
struct CornerPlayerPuck: View {
    /// Width the open bar may take, measured by the overlay that places it.
    let expandedWidth: CGFloat

    @Environment(PlayerState.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where it's heading; the four flags below are where it is.
    @State private var isOpen = false
    /// Phase 1: the glass is at the bar's width.
    @State private var isWide = false
    /// Phase 2: the glass is at the bar's height and radius; shared pieces
    /// are at the bar's size and place.
    @State private var isTall = false
    /// The bar-only parts are showing.
    @State private var showsDetail = false
    /// The puck-only parts (its transport, the progress line) are showing.
    @State private var showsCompact = true
    /// Bumped on every toggle, so a phase from an earlier toggle that
    /// finishes late doesn't start the next one.
    @State private var generation = 0

    @State private var expandedHeight: CGFloat = 92
    @State private var queueFrame: CGRect = .zero

    static let collapsedWidth: CGFloat = 320
    static let collapsedHeight: CGFloat = 56
    private static let collapsedRadius: CGFloat = 16
    private static let expandedRadius: CGFloat = 18

    private static let widen = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.28)
    private static let rise = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.26)
    private static let reveal = Animation.easeOut(duration: 0.2).delay(0.08)
    private static let conceal = Animation.easeIn(duration: 0.15)

    // The bar's pieces, from its padding (20 sides, 12 top) and 50pt row.
    private static let barInset: CGFloat = 20
    private static let barRowTop: CGFloat = 12
    private static let barRowHeight: CGFloat = 50
    private static let barCover: CGFloat = 48
    // The puck's: 8 in, 40pt cover, 10pt gap to the title, 10 trailing.
    private static let puckInset: CGFloat = 8
    private static let puckCover: CGFloat = 40
    private static let puckTrailing: CGFloat = 10
    /// The puck's title, between its cover and its transport and queue.
    private static let puckTextWidth: CGFloat = 120

    var body: some View {
        if let track = player.currentTrack {
            let radius = isTall ? Self.expandedRadius : Self.collapsedRadius
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let corner = UIStyle.shared.playerSide.topCorner
            ZStack(alignment: corner) {
                barLayer
                compactLayer(corner: corner)
                sharedLayer(track: track)
            }
            .frame(width: isWide ? expandedWidth : Self.collapsedWidth,
                   height: isTall ? expandedHeight : Self.collapsedHeight,
                   alignment: corner)
            .clipShape(shape)
            .background { PlayerGlass(track: track, cornerRadius: radius) }
            .contentShape(shape)
            .onTapGesture(perform: toggle)
            .help(isOpen ? "" : "Click to open the player")
        }
    }

    // MARK: Layers

    /// The bar, always laid out at full size: its own cover, title and queue
    /// button keep their room but aren't drawn (the shared layer draws them).
    private var barLayer: some View {
        FloatingPlayerBar()
            .frame(width: expandedWidth)
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(name: FloatingPlayerBar.hostSpace)
            .environment(\.puckQueueFrame, $queueFrame)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
            .opacity(showsDetail ? 1 : 0)
            .blur(radius: showsDetail ? 0 : 4)
            .allowsHitTesting(showsDetail)
            .accessibilityHidden(!showsDetail)
    }

    /// The puck's transport and progress line, where the puck sits.
    private func compactLayer(corner: Alignment) -> some View {
        HStack(spacing: 6) {
            Button { player.engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))
            .help("Previous")

            Button { player.engine.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))
            .help(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))
            .help("Next")
        }
        // Room for the queue button (drawn by the shared layer) after it.
        .padding(.trailing, Self.puckTrailing + 26 + 6)
        .frame(width: Self.collapsedWidth, height: Self.collapsedHeight, alignment: .trailing)
        .overlay(alignment: .bottom) {
            if UIStyle.shared.puckProgressLine { PuckProgressLine().padding(.horizontal, 18) }
        }
        .opacity(showsCompact ? 1 : 0)
        .blur(radius: showsCompact ? 0 : 4)
        .allowsHitTesting(showsCompact)
        .accessibilityHidden(!showsCompact)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
    }

    /// Cover, title and queue button: one view each, at the bar's size,
    /// pinned to the glass's leading and trailing edges and scaled and
    /// placed for the puck until the height opens.
    private func sharedLayer(track: Track) -> some View {
        let barTextLeading = Self.barInset + Self.barCover + Theme.Spacing.sm
        let puckTextLeading = Self.puckInset + Self.puckCover + 10
        let barRowMid = Self.barRowTop + Self.barRowHeight / 2
        let puckMid = Self.collapsedHeight / 2
        let textWidth = isTall
            ? FloatingPlayerBar.trackTextMaxWidth(contentWidth: expandedWidth - Self.barInset * 2)
            : Self.puckTextWidth
        // The queue button's distance from the bar's trailing edge, as the
        // bar lays it out (until measured, a stand-in).
        let barQueueTrailing = queueFrame == .zero ? 200 : expandedWidth - queueFrame.maxX
        let barQueueTop = queueFrame == .zero ? barRowMid - 13 : queueFrame.minY

        return ZStack(alignment: .topLeading) {
            ArtworkView(data: track.artwork, size: Self.barCover)
                .scaleEffect(isTall ? 1 : Self.puckCover / Self.barCover, anchor: .topLeading)
                .offset(x: isTall ? Self.barInset : Self.puckInset,
                        y: isTall ? Self.barRowTop + (Self.barRowHeight - Self.barCover) / 2
                                  : (Self.collapsedHeight - Self.puckCover) / 2)

            PlayerTrackText(track: track, showsDetail: showsDetail)
                .frame(width: textWidth, alignment: .leading)
                .frame(height: Self.barRowHeight)
                .offset(x: isTall ? barTextLeading : puckTextLeading,
                        y: (isTall ? barRowMid : puckMid) - Self.barRowHeight / 2)

            FloatingPlayerBar.queueToggleButton(player: player)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: -(isTall ? barQueueTrailing : Self.puckTrailing),
                        y: isTall ? barQueueTop : puckMid - 13)
        }
        .playerTrackMenu(track: track)
        // The glass's current size, not the stack's: the bar underneath is
        // always full width, so "fill" would put the leading edge off-glass.
        .frame(width: isWide ? expandedWidth : Self.collapsedWidth,
               height: isTall ? expandedHeight : Self.collapsedHeight,
               alignment: .topLeading)
    }

    // MARK: Sequencing

    private func toggle() {
        isOpen.toggle()
        generation += 1
        let token = generation
        let opening = isOpen

        if reduceMotion {
            // One short crossfade; the glass changes size at once.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                isWide = opening
                isTall = opening
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                showsDetail = opening
                showsCompact = !opening
            }
            return
        }

        if opening {
            withAnimation(Self.widen, completionCriteria: .logicallyComplete) {
                isWide = true
                showsCompact = false
            } completion: {
                guard token == generation else { return }
                withAnimation(Self.rise) { isTall = true }
                withAnimation(Self.reveal) { showsDetail = true }
            }
        } else {
            withAnimation(Self.conceal, completionCriteria: .logicallyComplete) {
                showsDetail = false
            } completion: {
                guard token == generation else { return }
                withAnimation(Self.rise, completionCriteria: .logicallyComplete) {
                    isTall = false
                } completion: {
                    guard token == generation else { return }
                    withAnimation(Self.widen) {
                        isWide = false
                        showsCompact = true
                    }
                }
            }
        }
    }
}

/// A 2pt line along the puck's lower edge showing how far through the track
/// playback is.
private struct PuckProgressLine: View {
    @Environment(PlayerState.self) private var player

    var body: some View {
        GeometryReader { geo in
            let duration = max(player.duration ?? 0, 0.001)
            let fraction = min(1, max(0, player.currentTime / duration))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textPrimary.opacity(0.12))
                Capsule().fill(Theme.textPrimary.opacity(0.85))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
