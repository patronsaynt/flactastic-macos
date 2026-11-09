import SwiftUI

/// The left of the stage, set like a CD's back insert: the wordmark, the
/// steps as numbered tracks (bars bouncing on the one playing, a tick on
/// each finished one with its answer under it), a scrubber under every
/// track, and the count at the foot. Finished tracks can be clicked to go
/// back to them.
struct OnboardingTracklist: View {
    let flow: OnboardingFlow
    let jump: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(height: 19)
                .opacity(flow.dealt && !flow.leaving ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(flow.leaving ? 0 : 0.2), value: flow.dealt)
                .animation(.easeOut(duration: 0.4), value: flow.leaving)

            VStack(spacing: 0) {
                ForEach(Array(flow.tracks.enumerated()), id: \.element) { i, track in
                    OnboardingTrackRow(flow: flow, track: track, index: i) { jump(i) }
                        .opacity(flow.dealt && !flow.leaving ? 1 : 0)
                        .blur(radius: flow.dealt && !flow.leaving ? 0 : 8)
                        .offset(x: flow.dealt && !flow.leaving ? 0 : (flow.leaving ? -60 : -40))
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(Double(i) * (flow.leaving ? 0.06 : 0.09)), value: flow.dealt)
                        .animation(.timingCurve(0.6, 0, 0.9, 0.4, duration: 0.5).delay(Double(i) * 0.06), value: flow.leaving)
                        .transition(.asymmetric(
                            insertion: .modifier(active: RowShift(x: 24), identity: RowShift(x: 0)),
                            removal: .modifier(active: RowShift(x: -24), identity: RowShift(x: 0))))
                }
            }
            .padding(.top, 58)
            .padding(.trailing, 40)

            Spacer(minLength: 0)

            Text("\(flow.tracks.count) tracks · about a minute")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .contentTransition(.numericText())
                .opacity(flow.dealt && !flow.leaving ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(flow.leaving ? 0 : 0.6), value: flow.dealt)
                .animation(.easeOut(duration: 0.4), value: flow.leaving)
        }
        .padding(.leading, 44)
        .padding(.top, 64)
        .padding(.bottom, 34)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.textPrimary.opacity(0.1))
                .frame(width: 1)
                .scaleEffect(y: flow.dealt && !flow.leaving ? 1 : 0, anchor: .top)
                .padding(.vertical, 64)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 1).delay(flow.leaving ? 0 : 0.3), value: flow.dealt)
                .animation(.timingCurve(0.6, 0, 0.9, 0.4, duration: 0.5), value: flow.leaving)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
    }
}

/// A row coming in or leaving as the fork rewrites the list: it slides and
/// blurs while its height opens or closes.
private struct RowShift: ViewModifier {
    let x: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(x == 0 ? 1 : 0)
            .blur(radius: x == 0 ? 0 : 6)
            .offset(x: x)
    }
}

private struct OnboardingTrackRow: View {
    let flow: OnboardingFlow
    let track: OnboardingFlow.Track
    let index: Int
    let onTap: () -> Void

    @State private var isHovering = false
    @State private var sweep: CGFloat = -1

    private var isDone: Bool { index < flow.at }
    private var isPlaying: Bool { index == flow.at }
    private var isSkipping: Bool { flow.skipping == track }

    /// Shown under finished tracks, and under the first while it plays.
    private var answer: String? {
        isDone || (isPlaying && index == 0) ? flow.answers[track] : nil
    }

    private var fill: Double {
        if isDone || isSkipping { return 1 }
        return isPlaying ? flow.progress : 0
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText(value: Double(index)))
                    .opacity(isDone || isPlaying ? 0 : 1)
                if isPlaying {
                    OnboardingEqualizer()
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .scaleEffect(isDone ? 1 : 0.4)
                    .opacity(isDone ? 1 : 0)
            }
            .frame(width: 52, height: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(isDone || isPlaying ? Theme.textPrimary : Theme.textTertiary)
                    .underline(isHovering && isDone, color: Theme.textPrimary.opacity(0.6))
                Text(answer ?? " ")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(answer == nil ? 0 : 1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 74)
        .overlay(alignment: .bottomLeading) { scrubber }
        .overlay {
            // The skip's sweep across the finished row.
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Theme.textPrimary.opacity(0.08), Theme.textPrimary.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width)
                    .offset(x: sweep * geo.size.width)
                    .opacity(sweep > -1 && sweep < 0.99 ? 1 : 0)
            }
            .clipped()
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isDone { onTap() } }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.4), value: flow.at)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: isDone)
        .onChange(of: isSkipping) { _, skipping in
            guard skipping else { return }
            sweep = -1
            withAnimation(.easeOut(duration: 0.45)) { sweep = 1 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index + 1), \(track.title)\(isPlaying ? ", current step" : isDone ? ", done" : "")")
        .accessibilityAddTraits(isDone ? .isButton : [])
        .accessibilityAction { if isDone { onTap() } }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.textPrimary.opacity(0.1)).frame(height: 1)
                Capsule()
                    .fill(Theme.textPrimary)
                    .frame(width: geo.size.width * fill, height: 3)
                    .shadow(color: Theme.textPrimary.opacity(isSkipping ? 0.7 : 0), radius: isSkipping ? 7 : 0)
                Circle()
                    .fill(Theme.textPrimary)
                    .frame(width: 9, height: 9)
                    .offset(x: geo.size.width * fill - 4.5)
                    .opacity(isPlaying && !isSkipping ? 1 : 0)
            }
            .frame(height: 9)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .offset(y: 4)
        }
        .animation(isSkipping ? .timingCurve(0.5, 0, 0.2, 1, duration: 0.3) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: fill)
        .animation(.easeOut(duration: 0.3), value: isSkipping)
    }
}
