import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Words for each track

/// What the stage says on a track: its title, the line under it, and the
/// buttons along the bottom.
struct OnboardingCopy: Equatable {
    var title: String
    var subtitle: String
    var isOptional = false
    /// The main button; nil hides it (Spotify, until connected).
    var primary: String? = "Continue"
    var primaryIcon = "forward.end.fill"
    var canContinue = true
    /// A second button beside it ("Skip for now").
    var secondary: String? = nil
}

extension OnboardingCopy {
    @MainActor
    static func `for`(_ flow: OnboardingFlow, settings: Settings, library: LibraryStore, spotify: SpotifyAuthController.ConnectionState) -> OnboardingCopy {
        switch flow.current {
        case .hello:
            return OnboardingCopy(title: "Your music, beautifully.", subtitle: "Are you new to FLACtastic, or a returning audiophile?")
        case .look:
            return OnboardingCopy(title: "Choose your look.", subtitle: "You can change this any time in Settings.")
        case .library:
            guard settings.lastRootPath != nil || ServerSession.current?.isActive == true else {
                return OnboardingCopy(title: "Where does your music live?", subtitle: "Pick your music folder, or start a new one.", canContinue: false)
            }
            if !flow.libraryScanned {
                return OnboardingCopy(title: "Listening…", subtitle: "Files only move when you say so.")
            }
            if library.tracks.isEmpty {
                return OnboardingCopy(title: "Ready for music.", subtitle: "It's empty for now. Downloads will land here.")
            }
            return OnboardingCopy(title: "Sounds like you.", subtitle: "Files only move when you say so.")
        case .restore:
            if let backup = flow.backup {
                let day = backup.createdAt.formatted(.dateTime.day().month(.wide))
                return OnboardingCopy(title: "Welcome back.", subtitle: "From your \(day) backup.",
                                      canContinue: flow.backupFolderIsHere)
            }
            if flow.lockedBackup != nil {
                return OnboardingCopy(title: "This backup is locked.", subtitle: "Enter its password to open it.", canContinue: false)
            }
            return OnboardingCopy(title: "Pick up where you left off.", subtitle: "Choose a .flactastic backup to restore.", canContinue: false)
        case .spotify:
            if case .connected = spotify {
                return OnboardingCopy(title: "Bring your playlists.", subtitle: "Rebuild your Spotify playlists from music you own.", isOptional: true)
            }
            return OnboardingCopy(title: "Bring your playlists.", subtitle: "Rebuild your Spotify playlists from music you own.", isOptional: true,
                                  primary: nil, secondary: "Skip for now")
        case .play:
            if flow.isRestoring {
                return OnboardingCopy(title: "Time to hear it properly.", subtitle: "Putting your backup back in place…",
                                      primary: "Restoring…", primaryIcon: "hourglass", canContinue: false)
            }
            return OnboardingCopy(
                title: "Time to hear it properly.",
                subtitle: flow.restoreError ?? (flow.branch == .new ? "Your library is ready." : "FLACtastic needs a quick restart to load your backup."),
                primary: flow.branch == .new ? "Enter FLACtastic" : "Restart FLACtastic",
                primaryIcon: flow.branch == .new ? "play.fill" : "arrow.clockwise")
        }
    }
}

// MARK: - Hello

struct OnboardingHelloStep: View {
    let flow: OnboardingFlow
    let choose: (OnboardingFlow.Branch) -> Void

    var body: some View {
        HStack(spacing: 14) {
            OnboardingChoice(icon: "opticaldisc", title: "New here", detail: "Start a fresh library.", isSelected: flow.branch == .new) { choose(.new) }
            OnboardingChoice(icon: "clock.arrow.circlepath", title: "Coming back", detail: "Restore from a backup.", isSelected: flow.branch == .back) { choose(.back) }
        }
    }
}

// MARK: - Look

struct OnboardingLookStep: View {
    @Environment(Settings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let pick: (AppTheme, CGPoint?) -> Void

    @State private var centres: [AppTheme: CGPoint] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            tile(.system, "Follow System", "Now \(systemIsDark ? "Dark" : "Light")")
            tile(.dark, "Dark", "Always dark")
            tile(.light, "Light", "Always light")
        }
    }

    /// The Mac's own look, whatever the app is forced to.
    private var systemIsDark: Bool {
        if settings.theme == .system { return colorScheme == .dark }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private func tile(_ theme: AppTheme, _ title: String, _ detail: String) -> some View {
        let isOn = settings.theme == theme
        return Button { pick(theme, centres[theme]) } label: {
            VStack(alignment: .leading, spacing: 0) {
                preview(theme)
                    .aspectRatio(1.42, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isOn ? Theme.textPrimary : Theme.textPrimary.opacity(0.12), lineWidth: isOn ? 2 : 1))
                    .shadow(color: .black.opacity(0.28), radius: 15, y: 12)
                HStack(spacing: 8) {
                    OnboardingRadio(isOn: isOn)
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.top, 12)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 26)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftStyle())
        // Where the flood pours from: this tile, however it was chosen.
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.minY + frame.width / 1.42 / 2)
        } action: { centres[theme] = $0 }
        .accessibilityLabel("\(title) appearance")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private func preview(_ theme: AppTheme) -> some View {
        switch theme {
        case .system:
            ZStack {
                MiniApp(isDark: !systemIsDark)
                MiniApp(isDark: systemIsDark)
                    .mask(DiagonalHalf())
            }
        case .dark: MiniApp(isDark: true)
        case .light: MiniApp(isDark: false)
        }
    }
}

/// A tiny FLACtastic in one look: a bar, a row of covers, two lines.
private struct MiniApp: View {
    let isDark: Bool

    var body: some View {
        let ink: Color = isDark ? .white : .black
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(ink.opacity(0.14)).frame(width: geo.size.width * 0.56, height: 8)
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ink.opacity([0.24, 0.16, 0.1, 0.19][i]))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .padding(.top, 12)
                Capsule().fill(ink.opacity(0.14)).frame(width: geo.size.width * 0.62, height: 5).padding(.top, 10)
                Capsule().fill(ink.opacity(0.08)).frame(width: geo.size.width * 0.4, height: 5).padding(.top, 6)
            }
            .padding(10)
        }
        .background(isDark ? Color.black : Color(white: 0.96))
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: rect.origin)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

private struct LiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Lifted(configuration: configuration) }

    private struct Lifted: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .offset(y: isHovering ? -3 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { isHovering = $0 }
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Library

struct OnboardingLibraryStep: View {
    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library
    let flow: OnboardingFlow
    let useDefault: () -> Void
    let choose: () -> Void
    var connect: () -> Void = {}
    let isTargeted: Bool
    @Environment(ServerSession.self) private var server

    var body: some View {
        if let profile = server.active {
            OnboardingDoneRow(title: profile.serverName,
                              detail: "\(library.tracks.count.formatted()) tracks · \(profile.address.label)") {
                Button("Change", action: connect).buttonStyle(QuietTextButtonStyle())
            }
            .transition(.opacity.combined(with: .offset(y: 12)))
        } else if let path = settings.lastRootPath {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingDoneRow(title: (path as NSString).lastPathComponent, detail: (path as NSString).abbreviatingWithTildeInPath) {
                    Button("Change", action: choose).buttonStyle(QuietTextButtonStyle())
                }
                if !(flow.libraryScanned && library.tracks.isEmpty) {
                    OnboardingScanReveal(flow: flow)
                        .padding(.top, 24)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .transition(.opacity.combined(with: .offset(y: 12)))
        } else {
            VStack(spacing: 10) {
                OnboardingOption(icon: "plus", title: "Use ~/Music/FLACtastic", detail: "A new folder in Music", action: "Create", isProminent: true, perform: useDefault)
                OnboardingOption(icon: "folder", title: "Choose a folder…", detail: "Use your existing library", action: "Browse", isTargeted: isTargeted, perform: choose)
                OnboardingOption(icon: "server.rack", title: "Connect to a server…", detail: "Your library on FLACtastic Server", action: "Connect", perform: connect)
            }
            .transition(.opacity)
        }
    }
}

/// The library arriving as it's read: covers streaming in, the Fidelidex
/// score and the counts climbing, the quality tiers filling.
struct OnboardingScanReveal: View {
    @Environment(LibraryStore.self) private var library
    let flow: OnboardingFlow

    @State private var stats = ScanStats()
    /// Albums in the order they turned up, newest last.
    @State private var arrived: [Album] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The newest covers, sliding along as each arrives: as many as
            // fit the column, so none slide under the case.
            GeometryReader { geo in
                HStack(spacing: 8) {
                    ForEach(arrived.suffix(max(1, Int((geo.size.width + 8) / 60))).reversed(), id: \.id) { album in
                        ArtworkView(data: album.artwork, size: 52, id: "album:\(album.id)", showsShadow: false, alwaysSquare: true)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 7, y: 6)
                            .transition(.asymmetric(
                                insertion: .modifier(active: CoverDrop(on: false), identity: CoverDrop(on: true)),
                                removal: .opacity))
                    }
                }
                .frame(width: geo.size.width, height: 58, alignment: .leading)
            }
            .frame(height: 58)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55), value: arrived.count)

            HStack(alignment: .lastTextBaseline, spacing: 34) {
                count(stats.score, "Fidelidex", size: 54)
                count(stats.tracks, "Tracks", size: 34)
                count(stats.albums, "Albums", size: 34)
            }
            .padding(.top, 16)

            // The quality tiers, in their own colours.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(stats.tiers, id: \.quality) { tier in
                        Rectangle().fill(tier.quality.color).frame(width: geo.size.width * tier.fraction)
                    }
                }
            }
            .frame(height: 6)
            .background(Theme.textPrimary.opacity(0.1))
            .clipShape(Capsule())
            .padding(.top, 18)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: stats)

            HStack(spacing: 16) {
                ForEach(stats.tiers, id: \.quality) { tier in
                    HStack(spacing: 6) {
                        Circle().fill(tier.quality.color).frame(width: 7, height: 7)
                        Text(tier.quality.label).foregroundStyle(Theme.textTertiary)
                        Text(tier.count.formatted()).fontWeight(.semibold).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.top, 10)

            HStack(spacing: 8) {
                Text(flow.libraryScanned ? "Scan complete" : "Scanning")
                if !flow.libraryScanned { ScanDots() }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 14)
        }
        .onChange(of: library.tracksRevision, initial: true) { _, _ in refresh() }
    }

    private func count(_ value: Int, _ label: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.formatted())
                .font(.system(size: size, weight: .heavy))
                .tracking(-size * 0.035)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText(value: Double(value)))
                .animation(.easeOut(duration: 0.4), value: value)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func refresh() {
        // Only files whose tags have been read count toward the score; the
        // first pass lists files before it knows their quality.
        let read = library.tracks.filter { $0.sampleRate != nil || $0.bitDepth != nil }
        let fidelity = LibraryFidelity(tracks: read)
        let albums = library.albums
        stats = ScanStats(
            score: fidelity.score,
            tracks: read.count,
            albums: albums.count,
            tiers: fidelity.tiers.map { ScanStats.Tier(quality: $0.quality, fraction: $0.fraction, count: Int(($0.fraction * Double(read.count)).rounded())) })
        if !library.tracks.isEmpty {
            flow.progress = 0.08 + 0.9 * Double(read.count) / Double(library.tracks.count)
        }
        let known = Set(arrived.map(\.id))
        let fresh = albums.filter { $0.artwork != nil && !known.contains($0.id) }
        if !fresh.isEmpty {
            arrived.append(contentsOf: fresh.prefix(6))
            if arrived.count > 40 { arrived.removeFirst(arrived.count - 40) }
        }
    }
}

struct ScanStats: Equatable {
    struct Tier: Equatable {
        let quality: AudioQuality
        let fraction: Double
        let count: Int
    }

    var score = 0
    var tracks = 0
    var albums = 0
    var tiers: [Tier] = []
}

private struct CoverDrop: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.6)
            .offset(y: on ? 0 : -14)
            .blur(radius: on ? 0 : 6)
    }
}

private struct ScanDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 4, height: 4)
                    .opacity(on ? 1 : 0.2)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}

// MARK: - Restore

struct OnboardingRestoreStep: View {
    let flow: OnboardingFlow
    let chooseBackup: () -> Void
    let unlock: (String) -> Void
    let chooseFolder: () -> Void
    let isTargeted: Bool

    @State private var password = ""
    @State private var shake = 0
    @FocusState private var passwordFocused: Bool

    var body: some View {
        if let backup = flow.backup {
            summary(backup)
                .transition(.opacity)
        } else if flow.lockedBackup != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SecureField("Backup password", text: $password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Theme.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(passwordFocused ? Theme.textPrimary : Theme.textPrimary.opacity(0.1), lineWidth: passwordFocused ? 1.5 : 1))
                        .focused($passwordFocused)
                        .onSubmit { unlock(password) }
                    Button("Unlock") { unlock(password) }
                        .buttonStyle(SheetPillStyle(isPrimary: true))
                }
                .keyframeAnimator(initialValue: 0.0, trigger: shake) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(-8, duration: 0.07)
                        LinearKeyframe(7, duration: 0.08)
                        LinearKeyframe(-4, duration: 0.08)
                        LinearKeyframe(2, duration: 0.08)
                        LinearKeyframe(0, duration: 0.08)
                    }
                }
                Text(flow.passwordError ?? " ")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.qualityLow)
                    .opacity(flow.passwordError == nil ? 0 : 1)
            }
            .onAppear { passwordFocused = true }
            .onChange(of: flow.passwordError) { _, error in
                if error != nil { shake += 1; password = "" }
            }
            .transition(.opacity)
        } else {
            OnboardingOption(icon: "doc", title: "Choose Backup…", detail: "or drop it here", action: "Browse", isProminent: true, isTargeted: isTargeted, perform: chooseBackup)
                .transition(.opacity)
        }
    }

    private func summary(_ backup: UserDataBackup.Archive) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(flow.backupContents.enumerated()), id: \.offset) { i, item in
                ReceiptRow(label: item.label, value: item.value, warns: item.warns, isIn: flow.receiptIn, delay: Double(i) * 0.11)
            }
            if !flow.backupFolderIsHere {
                Button { chooseFolder() } label: {
                    Label("Choose the music folder…", systemImage: "folder")
                }
                .buttonStyle(SheetPillStyle())
                .padding(.top, 14)
            }
            Text("FLACtastic restarts at the end to load your backup.\nBackups don't include Spotify, so sign in again next.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 14)
        }
    }
}

private struct ReceiptRow: View {
    let label: String
    let value: String
    let warns: Bool
    let isIn: Bool
    let delay: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: warns ? "exclamationmark.circle" : "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(warns ? Theme.textSecondary : Theme.textPrimary)
                .frame(width: 16)
            Text(label)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimary.opacity(0.1)).frame(height: 1) }
        .opacity(isIn ? 1 : 0)
        .blur(radius: isIn ? 0 : 4)
        .offset(y: isIn ? 0 : 10)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.6).delay(isIn ? 0.35 + delay : 0), value: isIn)
    }
}

// MARK: - Spotify

struct OnboardingSpotifyStep: View {
    @Environment(SpotifyAuthController.self) private var spotifyAuth

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isConnected ? "checkmark" : "music.note.list")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isConnected ? Theme.background : Theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(isConnected ? Theme.textPrimary : Theme.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Spotify")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(status)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 10)
            switch spotifyAuth.state {
            case .disconnected:
                Button("Connect") { Task { await spotifyAuth.connect() } }
                    .buttonStyle(SheetPillStyle())
            case .connecting:
                BrandLoader(height: 16)
            case .connected:
                EmptyView()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 14)
        .background(Theme.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.5), value: isConnected)
    }

    private var isConnected: Bool {
        if case .connected = spotifyAuth.state { return true }
        return false
    }

    private var status: String {
        switch spotifyAuth.state {
        case .disconnected: "Not connected"
        case .connecting: "Waiting for your browser…"
        case .connected(let name): "Connected as \(name)"
        }
    }
}
