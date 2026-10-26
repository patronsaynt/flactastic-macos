import SwiftUI
import AppKit

/// Lyrics visualizer mode. A slow field of the playing cover's own colors on
/// near-black; the lyrics on the left with the sung line forward, the track
/// on the right. Always dark, whatever the app theme: it's a stage.
struct LyricsVisualizerView: View {
    @Environment(PlayerState.self)       private var player
    @Environment(Settings.self)          private var settings
    @Environment(LyricsRemoteCache.self) private var cache
    @Environment(LyricsFetcher.self)     private var fetcher
    @Environment(\.topBarInset)          private var topBarInset

    @State private var palette: [Color] = LyricsField.fallback

    var body: some View {
        GeometryReader { geo in
            let side = min(280, max(180, geo.size.width * 0.22))
            HStack(alignment: .center, spacing: 64) {
                lyricsArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    ArtworkView(data: player.currentTrack?.artwork, size: side,
                                id: player.currentTrack.map { "track:\($0.id)" })
                    VisualizerTrackDetails(track: player.currentTrack,
                                           titleSize: 28, artistSize: 16, albumSize: 13, onDark: true)
                        .padding(.top, 22)
                    PlaybackProgressBar(
                        track: .white.opacity(0.22),
                        fill: .white,
                        labelStyle: AnyShapeStyle(Color.white.opacity(0.7))
                    )
                    .padding(.top, 18)
                    if showsUnsyncedNote {
                        UnsyncedLyricsNote()
                            .padding(.top, 28)
                            .transition(.opacity)
                    }
                }
                .frame(width: side)
            }
            .padding(.leading, 96)
            .padding(.trailing, 96)
            .padding(.top, topBarInset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background { LyricsField(colors: palette) }
        .environment(\.colorScheme, .dark)
        .task(id: player.currentTrack?.id) {
            await loadPalette()
            guard player.currentTrack?.isMixCompilation != true else { return }
            let enabled = settings.lyricsLookupEnabled
            let save = settings.saveLyricsToFiles
            fetcher.ensureLyrics(
                for: player.currentTrack,
                enabled: enabled,
                saveToFile: save
            )
            fetcher.prefetch(
                tracks: adjacentTracks.filter { $0.isMixCompilation != true },
                enabled: enabled,
                saveToFile: save
            )
        }
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsArea: some View {
        if player.currentTrack?.isMixCompilation == true {
            unavailable("Lyrics aren't available for mix compilations")
        } else if !settings.lyricsLookupEnabled {
            unavailable("Lyrics lookup is turned off in Settings")
        } else if let track = player.currentTrack {
            let key = LyricsCacheKey.make(
                artist: track.artist ?? track.albumArtist,
                title: track.title,
                duration: track.duration
            )
            if let entry = cache.entry(forKey: key) {
                if entry.notFound {
                    unavailable("Couldn't find lyrics for this song")
                } else if let lyrics = fetcher.parsedLyrics(from: entry, duration: track.duration ?? 0) {
                    if lyrics.isSynced {
                        TimedLyricsScroller(lyrics: lyrics)
                    } else {
                        // No timestamps in the source — scrolling these on a
                        // guessed schedule drifts against the vocals, so show
                        // them as a plain sheet instead.
                        UnsyncedLyricsSheet(lyrics: lyrics)
                            // New song → start again from its first line.
                            .id(track.id)
                    }
                } else {
                    unavailable("Couldn't find lyrics for this song")
                }
            } else if fetcher.hasRecentError(forKey: key) {
                unavailable("Couldn't find lyrics for this song")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    /// Whether the lyrics on screen are the plain, untimed kind, which the
    /// note under the track details explains.
    private var showsUnsyncedNote: Bool {
        guard let track = player.currentTrack,
              track.isMixCompilation != true,
              settings.lyricsLookupEnabled else { return false }
        let key = LyricsCacheKey.make(
            artist: track.artist ?? track.albumArtist,
            title: track.title,
            duration: track.duration
        )
        guard let entry = cache.entry(forKey: key), !entry.notFound,
              let lyrics = fetcher.parsedLyrics(from: entry, duration: track.duration ?? 0) else { return false }
        return !lyrics.isSynced
    }

    private func unavailable(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.7))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Palette

    private func loadPalette() async {
        let data = player.currentTrack?.artwork
        let sampled = await CoverPalette.load(for: data)
        guard !Task.isCancelled else { return }
        let colors = sampled.map { $0.nsSeries(3, dark: true).map { Color(nsColor: $0) } } ?? LyricsField.fallback
        withAnimation(.easeInOut(duration: 1.2)) { palette = colors }
    }

    // MARK: - Prefetch window

    /// Tracks adjacent to the current one whose lyrics should be warmed up
    /// in the background, so skipping forward / back feels instant.
    private var adjacentTracks: [Track] {
        let q = player.queue
        guard !q.isEmpty else { return [] }
        let cur = player.currentIndex
        return [-1, 1, 2].compactMap { delta in
            let idx = cur + delta
            return q.indices.contains(idx) ? q[idx] : nil
        }
    }
}

/// Three soft pools of the cover's colors drifting over near-black. Each pool
/// is a radial gradient (soft by nature, so nothing is blurred) moved by a
/// long repeating animation that Core Animation runs on its own: the view
/// body is never re-evaluated to drive it.
private struct LyricsField: View {
    let colors: [Color]

    static let fallback: [Color] = [Color(white: 0.32), Color(white: 0.22), Color(white: 0.27)]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height) * 0.8
            ZStack {
                Color(white: 0.024)
                pool(colors[0], size: size)
                    .offset(x: -geo.size.width * 0.32 + (drifting ? 220 : 0),
                            y: -geo.size.height * 0.36 + (drifting ? 120 : 0))
                    .scaleEffect(drifting ? 1.15 : 1)
                    .animation(drift(26), value: drifting)
                pool(colors[1 % colors.count], size: size)
                    .offset(x: geo.size.width * 0.38 + (drifting ? -180 : 0),
                            y: geo.size.height * 0.1 + (drifting ? -140 : 0))
                    .scaleEffect(drifting ? 0.9 : 1)
                    .animation(drift(31), value: drifting)
                pool(colors[2 % colors.count], size: size)
                    .offset(x: -geo.size.width * 0.05 + (drifting ? 160 : 0),
                            y: geo.size.height * 0.62 + (drifting ? -90 : 0))
                    .scaleEffect(drifting ? 1.2 : 1)
                    .animation(drift(23), value: drifting)
                RadialGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    center: UnitPoint(x: 0.3, y: 0.5),
                    startRadius: size * 0.3, endRadius: size
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // No `drawingGroup` here: flattening would re-rasterize the whole
        // field every frame of the drift, where unflattened the pools just
        // move as layers.
        .clipped()
        .onAppear { if !reduceMotion { drifting = true } }
        .allowsHitTesting(false)
    }

    private func pool(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.62), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }

    private func drift(_ seconds: Double) -> Animation {
        .easeInOut(duration: seconds).repeatForever(autoreverses: true)
    }
}

/// Drives `LyricsScrollerView` from the playback clock.
///
/// Split out so `LyricsVisualizerView` never reads `currentTime` in its own
/// body — otherwise the 20 Hz clock would re-evaluate the field, artwork
/// and marquees along with the lyrics. See the note on `PlaybackProgressBar`.
private struct TimedLyricsScroller: View {
    @Environment(PlayerState.self) private var player
    let lyrics: Lyrics

    var body: some View {
        // Paused schedule: lyrics only advance with playback time, so ticking
        // at 10 Hz while paused is pure redraw waste.
        TimelineView(.animation(minimumInterval: 0.1, paused: !player.isPlaying)) { _ in
            LyricsScrollerView(
                lyrics: lyrics,
                // Line changes should land when the words are heard, not when
                // they're rendered — on Bluetooth that's ~0.2 s later.
                currentTime: max(0, player.currentTime - player.engine.outputLatency),
                alignment: .leading,
                activeStyle: AnyShapeStyle(Color.white),
                maxWidthFraction: 1
            )
        }
    }
}

/// Lyrics with no timing data. Same carousel as synced lyrics, but the
/// active line is stepped through with ↑/↓ instead of following the clock —
/// any automatic schedule would be a guess and drift against the vocals.
/// The explanation sits with the track details (`UnsyncedLyricsNote`), so
/// the lyrics column holds only lyrics.
struct UnsyncedLyricsSheet: View {
    let lyrics: Lyrics

    @State private var index = 0
    @FocusState private var focused: Bool

    /// Blank lines are stanza breaks in plain text; as a carousel stop they'd
    /// just be an empty active line, so drop them.
    private var lines: Lyrics {
        Lyrics(lines: lyrics.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty },
               isSynced: false)
    }

    var body: some View {
        let lines = self.lines
        VStack(alignment: .leading, spacing: 0) {
            LyricsScrollerView(
                lyrics: lines,
                currentTime: 0,
                activeIndex: index,
                alignment: .leading,
                activeStyle: AnyShapeStyle(Color.white),
                maxWidthFraction: 1
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        // Key presses arrive through focus, after keyboard shortcuts — so the
        // visualizer mode dial's own ↑/↓ still win while it's open.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onTapGesture { focused = true }
        .onKeyPress(.upArrow) { step(-1, count: lines.lines.count) }
        .onKeyPress(.downArrow) { step(1, count: lines.lines.count) }
    }

    private func step(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        index = min(max(index + delta, 0), count - 1)
        return .handled
    }
}

/// Under the track details when its lyrics have no timing: what that means,
/// how to fix it, and how to move through the lines meanwhile.
private struct UnsyncedLyricsNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not time-synced", systemImage: "text.alignleft")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
            Text("Use \u{2191} and \u{2193} to move between lines. To sync them, right-click the track and choose \u{201C}Edit\u{2026}\u{201D}.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
    }
}
