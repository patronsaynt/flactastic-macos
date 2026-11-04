import SwiftUI

/// The player: a small glass puck in the bottom-right corner (cover, title,
/// previous, play, next, queue, a progress line along its lip). Clicking it
/// opens the same glass into the full floating player bar, in two moves: it
/// slides open to the left, then extends up, while the cover, title and
/// shared buttons slide across to their places in the bar. Clicking again
/// closes it in reverse.
struct CornerPlayerPuck: View {
    /// Width the open bar may take, measured by the overlay that places it.
    let expandedWidth: CGFloat

    @Environment(PlayerState.self) private var player
    @Namespace private var morph

    /// Which layout is in the glass: the bar's (while open or opening).
    @State private var showsBar = false
    /// First move: the glass is at the bar's width.
    @State private var isWide = false
    /// Second move: the glass is at the bar's height.
    @State private var isTall = false
    @State private var expandedHeight: CGFloat = 92
    @State private var sequence: Task<Void, Never>?

    static let collapsedWidth: CGFloat = 320
    static let collapsedHeight: CGFloat = 56
    private static let collapsedRadius: CGFloat = 16
    private static let expandedRadius: CGFloat = 18

    private static let slide = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
    private static let rise = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)
    /// Gap before the second move starts, so the first is mostly done.
    private static let stagger: Duration = .milliseconds(260)

    var body: some View {
        if let track = player.currentTrack {
            let radius = isTall ? Self.expandedRadius : Self.collapsedRadius
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack(alignment: .topTrailing) {
                // Pinned to the top-right of the glass, so the bar's top row
                // is what shows while it is only wide, and its seek bar comes
                // into view as the glass extends up. No fades: pieces either
                // slide (matched) or are uncovered by the growing glass.
                if showsBar {
                    FloatingPlayerBar()
                        .frame(width: expandedWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { expandedHeight = $0 }
                        .transition(.identity)
                } else {
                    puck(track: track)
                        .transition(.identity)
                }
            }
            .environment(\.puckMorph, morph)
            .frame(width: isWide ? expandedWidth : Self.collapsedWidth,
                   height: isTall ? expandedHeight : Self.collapsedHeight,
                   alignment: .topTrailing)
            .clipShape(shape)
            .background { PlayerGlass(track: track, cornerRadius: radius) }
            .contentShape(shape)
            .onTapGesture(perform: toggle)
            .help(showsBar ? "" : "Click to open the player")
            .onDisappear { sequence?.cancel() }
        }
    }

    private func toggle() {
        sequence?.cancel()
        if showsBar {
            sequence = Task {
                withAnimation(Self.rise) { isTall = false }
                try? await Task.sleep(for: Self.stagger)
                guard !Task.isCancelled else { return }
                withAnimation(Self.slide) {
                    showsBar = false
                    isWide = false
                }
            }
        } else {
            sequence = Task {
                withAnimation(Self.slide) {
                    showsBar = true
                    isWide = true
                }
                try? await Task.sleep(for: Self.stagger)
                guard !Task.isCancelled else { return }
                withAnimation(Self.rise) { isTall = true }
            }
        }
    }

    private func puck(track: Track) -> some View {
        HStack(spacing: 6) {
            ArtworkView(data: track.artwork, size: 40)
                .puckMatched("cover")
                .padding(.trailing, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let artist = ArtistResolver.displayString(track.artist) {
                    Text(artist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .puckMatched("text")

            Button { player.engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))
            .help("Previous")
            .puckMatched("previous")

            Button { player.engine.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))
            .help(player.isPlaying ? "Pause" : "Play")
            .puckMatched("play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(GlassIconButtonStyle(isProminent: true))
            .help("Next")
            .puckMatched("next")

            FloatingPlayerBar.queueToggleButton(player: player)
                .puckMatched("queue")
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(width: Self.collapsedWidth, height: Self.collapsedHeight)
        .overlay(alignment: .bottom) { PuckProgressLine().padding(.horizontal, 18) }
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

// MARK: - Morph

extension EnvironmentValues {
    /// Set inside the corner puck so the puck's pieces and the bar's slide
    /// between each other; nil everywhere else (the menu bar player).
    @Entry var puckMorph: Namespace.ID?
}

private struct PuckMatched: ViewModifier {
    let id: String
    @Environment(\.puckMorph) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Pairs this piece with its twin in the other state of the corner puck.
    func puckMatched(_ id: String) -> some View { modifier(PuckMatched(id: id)) }
}
