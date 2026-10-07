import SwiftUI

struct SeekBarView: View {
    /// Larger geometry for the main floating player bar; the menu-bar and
    /// mini-player instances keep the original compact sizing.
    var prominent = false

    @Environment(PlayerState.self) private var player
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private var trackHeight: CGFloat { prominent ? 5 : 4 }
    private var thumbSize: CGFloat { prominent ? 14 : 12 }

    var body: some View {
        let duration = player.duration ?? 1
        let displayTime = isDragging ? dragValue : player.currentTime
        let progress = duration > 0 ? displayTime / duration : 0

        VStack(spacing: Theme.Spacing.xs) {
            GeometryReader { geo in
                let width = geo.size.width

                ZStack(alignment: .leading) {
                    // Track background
                    // The main bar is glass, so its groove is a tint of the
                    // ink rather than an opaque surface.
                    Capsule()
                        .fill(prominent ? Theme.textPrimary.opacity(0.14) : Theme.surfaceElevated)
                        .frame(height: trackHeight)

                    // Filled portion
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, min(CGFloat(progress) * width, width)), height: 5)

                    // Thumb
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(prominent ? 0.3 : 0), radius: 3, y: 1)
                        .offset(x: max(0, min(CGFloat(progress) * width - thumbSize / 2, width - thumbSize)))
                }
                .frame(height: thumbSize)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(value.location.x / width, 1))
                            let time = fraction * duration
                            if !isDragging {
                                isDragging = true
                            }
                            dragValue = time
                        }
                        .onEnded { value in
                            let fraction = max(0, min(value.location.x / width, 1))
                            let time = fraction * duration
                            player.engine.seek(to: time)
                            isDragging = false
                        }
                )
            }
            .frame(height: prominent ? 18 : 16)

            HStack {
                Text(FormatUtils.formatDuration(displayTime))
                    .font(prominent ? .system(size: 12) : Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                Spacer()
                Text("-\(FormatUtils.formatDuration(max(0, duration - displayTime)))")
                    .font(prominent ? .system(size: 12) : Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
    }
}
