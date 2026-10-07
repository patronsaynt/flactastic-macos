import SwiftUI

struct VisualizerView: View {
    @Environment(PlayerState.self) private var player
    @Environment(Settings.self)    private var settings

    @State private var analyzer = SpectrumAnalyzer()

    var body: some View {
        @Bindable var settings = settings
        ZStack {
            // The canvas fills the window, running up under the floating top
            // bar (which ContentView layers above it); fullscreen takes the
            // bar away entirely.
            Theme.background

            content(for: settings.visualizerMode)
                .id(settings.visualizerMode)
                .transition(.opacity)
                // Every mode is purely decorative — nothing in the canvas is
                // clickable. It has to opt out of hit testing because
                // `.clipped()` bounds drawing but NOT interaction: the Lyrics
                // backdrop is scaled 1.25× and blurred 60pt, so its hit area
                // reaches well past the canvas. If a mode ever grows a control, it should
                // re-enable hit testing on just that control.
                .allowsHitTesting(false)

            // Hidden affordance: pressing Q toggles the queue panel while
            // the visualizer is on screen.
            Button("") { player.isQueueVisible.toggle() }
                .keyboardShortcut("q", modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            VisualizerModeWheel(mode: $settings.visualizerMode)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: settings.visualizerMode)
        .onAppear { syncTap(for: settings.visualizerMode) }
        .onDisappear { analyzer.detach() }
        .onChange(of: settings.visualizerMode) { _, newMode in
            // Installing or removing the AVAudioEngine tap reconfigures the
            // engine and allocates FFT state — inline, that lands squarely on
            // the cross-fade's first frame and shows up as a hitch. Hopping a
            // runloop turn lets the transition start before the audio work.
            Task { @MainActor in syncTap(for: newMode) }
        }
    }

    @ViewBuilder
    private func content(for mode: VisualizerMode) -> some View {
        switch mode {
        case .albumArtLarge, .albumArtLargeDetails,
             .albumArtSmallDetails,
             .albumArtWheel:
            AlbumArtVisualizerView(mode: mode)
        case .lyrics:
            LyricsVisualizerView()
        case .spectrumRadial, .spectrumHorizontal, .spectrogram:
            SpectrumVisualizerView(mode: mode, analyzer: analyzer)
        }
    }

    private func syncTap(for mode: VisualizerMode) {
        if mode.requiresAudioTap {
            analyzer.attach(to: player.engine)
        } else {
            analyzer.detach()
        }
    }
}
