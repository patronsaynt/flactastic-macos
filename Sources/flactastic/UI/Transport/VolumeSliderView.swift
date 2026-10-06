import SwiftUI

struct VolumeSliderView: View {
    @Environment(PlayerState.self) private var player
    @Environment(Settings.self) private var settings
    @Environment(CastManager.self) private var cast

    var body: some View {
        @Bindable var player = player
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)

            Slider(value: $player.volume, in: 0...1) { _ in
                // A network speaker's volume is its own; keep the saved
                // local volume for when playback returns to this Mac.
                if !cast.isStreamingRemotely { settings.volume = player.volume }
            }
            .tint(Theme.accent)
            .disabled(!cast.isVolumeControllable)
            .frame(width: 64)
            .onChange(of: player.volume) { _, newValue in
                player.engine.setVolume(newValue)
            }

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
