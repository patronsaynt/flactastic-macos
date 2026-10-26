import SwiftUI

/// First-run setup, laid out as a stage: big type on the left over a blurred
/// cover, a fan of album covers on the right, and progress along the bottom.
/// Steps: welcome, look, library, Spotify (optional), done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, look, library, spotify, done

        var name: String {
            switch self {
            case .welcome: return "Welcome"
            case .look:    return "Look"
            case .library: return "Library"
            case .spotify: return "Spotify"
            case .done:    return "Done"
            }
        }
    }

    @Environment(Settings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome
    /// Which way the last step change went, for the slide direction.
    @State private var forward = true

    /// Called when the user finishes ("Enter FLACtastic"). Defaults to
    /// marking onboarding complete in `Settings`. The app passes its own to
    /// also end a debug replay; the preview window closes itself instead.
    var onFinish: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                OnboardingCoverFan()
                    .frame(width: min(460, geo.size.width * 0.38))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 70)

                Wordmark(height: 20)
                    .padding(.leading, 80)
                    .padding(.top, 64)

                stepContent
                    .frame(width: min(560, geo.size.width * 0.5), alignment: .leading)
                    .padding(.leading, 80)
                    .padding(.top, 150)

                progressBar
                    .padding(.horizontal, 80)
                    .padding(.bottom, 44)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            // Pinned to the window's top-left, and the backdrop is a
            // background, so nothing here can grow the stage past the window.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background { OnboardingBackdrop() }
            .clipped()
        }
        .background(Theme.background)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch step {
            case .welcome: OnboardingWelcomeStep(onNext: advance)
            case .look:    OnboardingLookStep(onNext: advance)
            case .library: OnboardingLibraryStep(onNext: advance)
            case .spotify: OnboardingSpotifyStep(onNext: advance)
            case .done:    OnboardingDoneStep(onFinish: finish)
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 26 : -26)),
            removal: .opacity.combined(with: .offset(x: forward ? -26 : 26))
        ))
    }

    private var progressBar: some View {
        HStack(spacing: 24) {
            Group {
                if step != .welcome {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(QuietTextButtonStyle())
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                }
            }
            .frame(width: 96, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Theme.textPrimary : Theme.textPrimary.opacity(0.1))
                        .frame(height: 3)
                }
            }
            .frame(maxWidth: 420)
            .animation(.easeOut(duration: 0.4), value: step)

            Text("\(step.rawValue + 1) of \(Step.allCases.count) · \(step.name)")
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.6)
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        forward = true
        withAnimation(motion) { step = next }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        withAnimation(motion) { step = previous }
    }

    private func finish() {
        if let onFinish {
            onFinish()
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                settings.hasCompletedOnboarding = true
            }
        }
    }
}
