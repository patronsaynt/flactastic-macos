import SwiftUI

/// Each tab's one-page tutorial: a heading and four short tips.
struct TabTutorial {
    struct Tip {
        let title: String
        let detail: String
    }

    let heading: String
    let tips: [Tip]

    static func `for`(_ tab: AppTab) -> TabTutorial {
        switch tab {
        case .home:
            return TabTutorial(heading: "Your listening, at a glance", tips: [
                Tip(title: "Lyric of the day", detail: "A line from a song you own, new each launch. Pin it to keep it."),
                Tip(title: "Recently Played", detail: "Pick up any album or playlist where you left off."),
                Tip(title: "Your Listening", detail: "Time, streaks, top albums and your Fidelidex score update as you play."),
                Tip(title: "Colors", detail: "Home takes its colors from the banner image."),
            ])
        case .collection:
            return TabTutorial(heading: "Everything you own", tips: [
                Tip(title: "Albums, Artists, Tracks", detail: "Switch views in the header; sort and search from there too."),
                Tip(title: "The shelf", detail: "Scroll through your albums and click a cover to open it."),
                Tip(title: "Right-click anything", detail: "Play it next, add it to the queue or a playlist, or edit its details."),
                Tip(title: "Quality badges", detail: "Every file's real format and resolution, read from the file itself."),
            ])
        case .playlists:
            return TabTutorial(heading: "Your playlists", tips: [
                Tip(title: "Pick one on the left", detail: "It opens on the stage beside it, ready to play or shuffle."),
                Tip(title: "Sort", detail: "A–Z, Z–A or recently played."),
                Tip(title: "Edit", detail: "Change the name, cover and description from the playlist's page."),
                Tip(title: "They follow your files", detail: "Reorganize your folders and your playlists keep working."),
            ])
        case .download:
            return TabTutorial(heading: "Download in lossless", tips: [
                Tip(title: "Paste a link", detail: "From Spotify, Tidal, Qobuz, Amazon Music or SoundCloud."),
                Tip(title: "Download options", detail: "Pick a quality once; it applies to every track."),
                Tip(title: "Your Spotify playlists", detail: "Connect Spotify to list your playlists and download them whole."),
                Tip(title: "Stay safe", detail: "Use a VPN, and only download music you own or have a license to."),
            ])
        case .organizer:
            return TabTutorial(heading: "Keep your folders tidy", tips: [
                Tip(title: "Build a structure", detail: "Stack levels like Artist / Album to decide where files go."),
                Tip(title: "Name your files", detail: "Click a tag to add it to a folder or file name pattern."),
                Tip(title: "Preview first", detail: "See exactly where every file will land before anything moves."),
                Tip(title: "Nothing moves until you say so", detail: "Your files stay put until you apply."),
            ])
        case .visualizer:
            return TabTutorial(heading: "Watch what you hear", tips: [
                Tip(title: "Change modes", detail: "Move the pointer to the left edge to open the dial, then scroll or drag to turn it."),
                Tip(title: "The queue", detail: "Press Q to show or hide it."),
                Tip(title: "Colors from the cover", detail: "Lyrics and the spectrogram take their colors from the album art."),
                Tip(title: "Full screen", detail: "Hides the top bar for the whole picture."),
            ])
        }
    }
}

/// Shows the selected tab's tutorial card the first time the tab is opened
/// (and on every visit while Settings → Debug → "Show tutorials on every
/// visit" is on). Dismissing it records the tab in `Settings.seenTutorials`.
/// Sits under the top bar, so the tabs stay reachable behind it.
struct TabTutorialOverlay: View {
    @Environment(NavigationRouter.self) private var router
    @Environment(Settings.self) private var settings
    @Environment(DebugState.self) private var debugState
    @Environment(LibraryStore.self) private var library

    @State private var showing: AppTab?

    var body: some View {
        ZStack {
            if let tab = showing {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(tab) }
                    .transition(.opacity)

                TabTutorialCard(tab: tab, tutorial: .for(tab)) { dismiss(tab) }
                    .id(tab)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: 12)))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45), value: showing)
        .onAppear { update(for: router.selectedTab) }
        .onChange(of: router.selectedTab) { _, tab in update(for: tab) }
        .onChange(of: debugState.tutorialsEveryVisitActive) { _, _ in update(for: router.selectedTab) }
        .onChange(of: library.hasCompletedInitialLoad) { _, _ in update(for: router.selectedTab) }
    }

    private func update(for tab: AppTab) {
        // Not over the loading cover: wait for the first scan to finish.
        guard library.hasCompletedInitialLoad else { showing = nil; return }
        let due = debugState.tutorialsEveryVisitActive || !settings.seenTutorials.contains(tab.rawValue)
        showing = due ? tab : nil
    }

    private func dismiss(_ tab: AppTab) {
        settings.seenTutorials.insert(tab.rawValue)
        showing = nil
    }
}

private struct TabTutorialCard: View {
    let tab: AppTab
    let tutorial: TabTutorial
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tutorial.heading)
                .font(.system(size: 34, weight: .heavy))
                .tracking(-1.2)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A quick tour of \(tab.rawValue). You'll only see this once.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
                .padding(.bottom, 20)

            ForEach(Array(tutorial.tips.enumerated()), id: \.offset) { index, tip in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(tip.detail)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
            }

            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
            .background {
                Button("", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .frame(width: 540)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .light ? 0.18 : 0.6), radius: 50, y: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.rawValue) tips")
    }
}
