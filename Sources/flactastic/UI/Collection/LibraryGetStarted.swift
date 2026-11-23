import SwiftUI

/// What an empty library shows, on Home and in every Collection view: the
/// onboarding case, still blank, beside the ways to bring music in.
///
/// On a server profile an empty library usually means the server hasn't
/// answered yet, so while it's connecting or out of reach this says so (the
/// disc spins while it connects) instead of offering imports.
struct LibraryGetStarted: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServerSession.self) private var server
    @Environment(Settings.self) private var settings
    @Environment(NavigationRouter.self) private var router
    @Environment(ImportCoordinator.self) private var importCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasEntered = false

    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }

    private enum Situation: Equatable {
        case empty
        case connecting(String)
        case unreachable(String)
        case signedOut(String)
    }

    private var situation: Situation {
        guard let profile = server.active else { return .empty }
        switch server.status {
        case .ready: return .empty
        case .idle, .connecting: return .connecting(profile.serverName)
        case .unreachable: return .unreachable(profile.serverName)
        case .signedOut, .identityChanged: return .signedOut(profile.serverName)
        }
    }

    private var title: String {
        switch situation {
        case .empty: server.active.map { "Nothing on \($0.serverName) yet" } ?? "Nothing on the shelf yet"
        case .connecting(let name): "Connecting to \(name)"
        case .unreachable(let name): "Can’t reach \(name)"
        case .signedOut(let name): "Signed out of \(name)"
        }
    }

    private var detail: String {
        switch situation {
        case .empty: "Add some music and it lands here."
        case .connecting: "Your library shows up as soon as it answers."
        case .unreachable: "It reconnects on its own when the server’s back."
        case .signedOut: "Sign in again from Settings to see your library."
        }
    }

    /// The case at rest, turned to show its spine with the blank disc part
    /// way out. It drifts onto this mark once as the view appears.
    private var pose: CasePose {
        hasEntered || calmMotion
            ? CasePose(x: 0, y: 0, zoom: 1, tilt: 8, roll: -3, turn: 28, disc: 0.34)
            : CasePose(x: 60, y: 14, zoom: 0.9, tilt: 14, roll: 4, turn: 48, disc: 0)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 64) {
                copyColumn.frame(width: 440, alignment: .leading)
                jewelCase(size: 230)
                    .frame(width: 330, height: 300)
            }
            copyColumn.frame(maxWidth: 440, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(calmMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(0.15)) {
                hasEntered = true
            }
        }
    }

    // MARK: Copy and actions

    private var copyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)

            if situation == .empty {
                VStack(spacing: 10) {
                    ForEach(Array(actions.enumerated()), id: \.element.title) { index, item in
                        OnboardingOption(
                            icon: item.icon,
                            title: item.title,
                            detail: item.detail,
                            action: item.action,
                            isProminent: index == 0,
                            perform: item.perform
                        )
                        .opacity(hasEntered || calmMotion ? 1 : 0)
                        .offset(y: hasEntered || calmMotion ? 0 : 12)
                        .animation(
                            calmMotion ? .easeOut(duration: 0.25)
                                : .timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(0.25 + Double(index) * 0.06),
                            value: hasEntered
                        )
                    }
                }
                .padding(.top, 26)

                if server.active == nil, library.rootURL != nil {
                    Text("Files you add in Finder show up on their own, or press ⌘R.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 14)
                        .padding(.leading, 2)
                }
            }
        }
    }

    private struct Item {
        let icon: String
        let title: String
        let detail: String
        var action: String? = nil
        let perform: () -> Void
    }

    private var actions: [Item] {
        var items = [
            Item(icon: "square.stack", title: "Import an album",
                 detail: "Copy it in and tag every track at once.") { importCoordinator.begin(.album) },
            Item(icon: "music.note", title: "Import a track",
                 detail: "One song from anywhere on your Mac.") { importCoordinator.begin(.track) },
        ]
        if settings.showDownloadTab {
            items.append(Item(icon: "arrow.down.circle", title: "Find music",
                              detail: "Search for albums in lossless.") { router.selectedTab = .download })
        }
        if server.active == nil, let root = library.rootURL {
            items.append(Item(icon: "folder", title: "Open your music folder",
                              detail: (root.path as NSString).abbreviatingWithTildeInPath,
                              action: "Finder") { NSWorkspace.shared.open(root) })
        }
        return items
    }

    // MARK: The case

    private func jewelCase(size: CGFloat) -> some View {
        OnboardingCase(
            pose: pose,
            album: nil,
            size: size,
            spin: { if case .connecting = situation { 300 } else { 0 } }()
        )
        .opacity(hasEntered || calmMotion ? 1 : 0)
        .animation(calmMotion ? .easeOut(duration: 0.25) : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(0.15), value: hasEntered)
    }
}
