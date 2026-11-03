import SwiftUI

/// The top of Home: the wordmark and today's date, the day's lyric on the
/// left, and on the right the song's album as the Collection rack's own
/// jewel case, hanging in the air close to you with its disc half out.
/// The first time Home shows in a launch, the case is thrown in from the
/// right and caught just short of the glass; after that it holds still.
struct HomeTop: View {
    struct Song {
        let title: String
        let artist: String?
        /// The album the song is on in the library; nil leaves the case out.
        let album: Album?
        /// The album's artists, split as the rack splits them for its spines.
        let albumArtists: [String]
        /// "From Burning Out (2026)".
        let story: String?
    }

    /// Nil before a lyric is picked, or on an empty library: the top then
    /// carries `welcome` instead.
    let lyric: String?
    let song: Song?
    var welcome: (title: String, detail: String?)? = nil
    /// The artist's colour, for the light the case hangs in.
    let glow: Color?
    let isPinned: Bool
    let onPin: () -> Void
    let calmMotion: Bool

    /// When the words arrive: as the throw is caught, or at once.
    @State private var wordsIn = false

    static let wordmarkHeight: CGFloat = 60
    /// As tall as the case at rest, so the left side centres against it.
    static let height: CGFloat = 520

    var body: some View {
        // The wordmark, the date under it and the words as one block, sat
        // low against the case on the right.
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Wordmark(height: Self.wordmarkHeight)
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                words
                    .frame(width: geo.size.width * 0.53, alignment: .leading)
            }
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Self.height)
        // The case is big and near, so it's let a little over the edge.
        .overlay(alignment: .trailing) {
            if let album = song?.album {
                ThrownCase(album: album, artists: song?.albumArtists ?? [], glow: glow, calmMotion: calmMotion) {
                    withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)) { wordsIn = true }
                }
                .id(album.id)
            }
        }
        .onAppear {
            // Without a case to wait for, the words come in on their own.
            if song?.album == nil || calmMotion || ThrownCase.hasThrown {
                withAnimation(calmMotion ? .easeOut(duration: 0.3) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.8)) { wordsIn = true }
            }
        }
    }

    // MARK: Words

    @ViewBuilder
    private var words: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lyric {
                Text("“\(lyric)”")
                    .font(.system(size: 50, weight: .heavy).italic())
                    .tracking(-1.2)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.55)
                    .fixedSize(horizontal: false, vertical: true)
                    .blur(radius: wordsIn ? 0 : 8)
                if let song { songLine(song).padding(.top, 20) }
            } else if let welcome {
                Text(welcome.title)
                    .font(.system(size: 50, weight: .heavy))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let detail = welcome.detail {
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 14)
                }
            }
        }
        .opacity(wordsIn ? 1 : 0)
        .offset(y: wordsIn || calmMotion ? 0 : 14)
    }

    private func songLine(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(song.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let artist = song.artist {
                    Text("—")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    ArtistLink(credit: artist, font: .system(size: 14), color: Theme.textSecondary)
                }
                Button(action: onPin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(isPinned ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(PinButtonStyle())
                .help(isPinned ? "Unpin lyric" : "Keep this lyric on Home")
                .accessibilityLabel(isPinned ? "Unpin lyric" : "Pin lyric")
            }
            .lineLimit(1)
            if let story = song.story {
                Text(story)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - The thrown case

/// The rack's jewel case and disc, thrown at you from the right: it flies in
/// small and tumbling, and stops dead just short of the
/// glass with a jolt, the disc caught halfway out from behind it. Played
/// once per launch; every other time Home shows, the case is already there.
private struct ThrownCase: View {
    let album: Album
    let artists: [String]
    let glow: Color?
    let calmMotion: Bool
    /// Called as the throw is caught, for the words to follow.
    let onCaught: () -> Void

    @Environment(Settings.self) private var settings
    @Environment(NavigationRouter.self) private var router
    @Environment(\.displayScale) private var displayScale

    /// When the throw started; nil shows the case at rest.
    @State private var thrownAt: Date?
    @State private var isFlying = false
    /// Hidden until the throw starts, rather than shown at rest and then
    /// snatched away to fly in.
    @State private var isWaiting: Bool

    init(album: Album, artists: [String], glow: Color?, calmMotion: Bool, onCaught: @escaping () -> Void) {
        self.album = album
        self.artists = artists
        self.glow = glow
        self.calmMotion = calmMotion
        self.onCaught = onCaught
        _isWaiting = State(initialValue: !Self.hasThrown && !calmMotion)
    }

    /// Once a launch: the throw is the app opening, not every visit to Home.
    @MainActor static var hasThrown = false

    static let size: CGFloat = 430
    static let depth: CGFloat = (size * 0.078).rounded()

    var body: some View {
        // Only redrawn while it flies; at rest it's one still picture.
        TimelineView(.animation(paused: !isFlying)) { context in
            let pose = thrownAt.map { Pose.at(context.date.timeIntervalSince($0)) } ?? .rest
            caseView(pose)
        }
        .opacity(isWaiting ? 0 : 1)
        .frame(width: Self.size * 1.62, height: Self.size)
        .padding(.trailing, -24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await throwIfFirst() }
    }

    private func caseView(_ pose: Pose) -> some View {
        let size = Self.size
        return ZStack {
            // The light it hangs in, in the artist's colour, and its shadow
            // on the floor far below.
            RadialGradient(colors: [(glow ?? .white).opacity(0.32), (glow ?? .white).opacity(0.08), .clear],
                           center: .center, startRadius: 0, endRadius: size * 0.95)
                .frame(width: size * 2, height: size * 1.6)
                .opacity(pose.glow)
            // A soft gradient rather than a blurred shape: no offscreen pass.
            EllipticalGradient(colors: [.black.opacity(0.55), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: size * 1.2, height: 50)
                .scaleEffect(x: 0.5 + 0.5 * pose.near, y: 1)
                .opacity(0.7 * pose.near)
                .offset(x: pose.x * 0.7, y: size * 0.68)

            ZStack {
                // The disc behind the case, slid out to the right in the
                // case's own plane, so it turns with it.
                RackDisc(album: album, colors: RackDisc.colors(for: album), diameter: size * 0.92, isSpinning: false)
                    .projectionEffect(discProjection(turn: pose.turn, slide: pose.disc * size))
                RackBox(album: album, credit: RackLayout.credit(of: album), design: design, size: size, depth: Self.depth,
                        clearCase: settings.clearCaseLook, blurArt: settings.blurSpineArt, style: settings.spineStyle,
                        scanFolder: settings.useSpineScans ? album.tracks.first?.url.deletingLastPathComponent() : nil,
                        castsShadow: !isFlying, angle: pose.turn)
            }
            .rotation3DEffect(.degrees(pose.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .rotationEffect(.degrees(pose.roll))
            .scaleEffect(pose.scale)
            // No live speed blur: a blur whose radius changes every frame
            // re-renders the whole projected case offscreen on each one, and
            // was much of why the throw stuttered.
            .offset(x: pose.x - size * 0.1, y: pose.y)
        }
        .offset(pose.jolt)
    }

    /// The disc's place behind the case: slid `slide` along the case's
    /// width, just behind its back, and turned and seen in perspective
    /// exactly as `RackBox` projects its faces, so the two read as one object.
    private func discProjection(turn: Double, slide: CGFloat) -> ProjectionTransform {
        let size = Self.size, diameter = size * 0.92, depth = Self.depth
        let a = turn * .pi / 180
        var rotation = CATransform3DIdentity
        rotation.m11 = cos(a); rotation.m13 = -sin(a)
        rotation.m31 = sin(a); rotation.m33 = cos(a)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (size * 3.2)
        // The same shift `RackBox` makes to keep its nearest face at true size.
        let shift = -(size / 2) * max(0, sin(a)) - (depth / 2) * max(0, cos(a))

        var t = CATransform3DMakeTranslation(-diameter / 2 + slide, -diameter / 2, -depth / 2 - 1)
        t = CATransform3DConcat(t, rotation)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, 0, shift))
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(diameter / 2, diameter / 2, 0))
        return ProjectionTransform(t)
    }

    private var design: SpineDesign {
        SpineDesignCache.shared.design(
            for: album, credit: RackLayout.credit(of: album), shuffles: settings.spineShuffles[album.id] ?? 0,
            options: settings.spineOptions, overrides: settings.spineOverrides[album.id] ?? SpineOverrides(), artists: artists)
    }

    private func throwIfFirst() async {
        guard !Self.hasThrown, !calmMotion else { return }
        Self.hasThrown = true
        // Decode the cover at the case's size and sample its colours for the
        // disc first, as the rack does, so neither pops in mid-flight.
        if let data = album.artwork, !data.isEmpty {
            async let art = ArtworkImageCache.shared.thumbnailAsync(
                for: data, id: "album:\(album.id)", pointSize: ArtworkImageCache.decodePointSize(for: Self.size), scale: displayScale)
            async let palette = CoverPalette.load(for: data)
            _ = await (art, palette)
        }
        // Throw once the launch cover has faded into Home. The cover holds on
        // black while the library's launch work runs on the main thread —
        // landing mid-flight, that work froze the case and then jumped it
        // ahead (the pose follows the clock). Capped in case the flag is
        // never seen.
        let deadline = ContinuousClock.now + .seconds(15)
        while !router.isLaunchRevealed, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else {
            isWaiting = false
            return
        }
        thrownAt = .now
        isFlying = true
        isWaiting = false
        try? await Task.sleep(for: .seconds(Pose.caughtAt))
        onCaught()
        try? await Task.sleep(for: .seconds(Pose.duration - Pose.caughtAt))
        // Landed: stop redrawing, and let the case's shadow settle in.
        withAnimation(.easeOut(duration: 0.35)) { isFlying = false }
        thrownAt = nil
    }
}

/// Where the thrown case is at a moment of the throw. Keyframes over its
/// offset (x, y), how near it is (scale), its tumble (tilt about the
/// horizontal, roll in the plane), which way it faces (`turn`, the rack's
/// own angle: positive shows the spine), how far the disc has slid out (as a
/// share of the case's size). Each stretch has its ease.
private struct Pose {
    var x: CGFloat, y: CGFloat, scale: CGFloat, tilt: Double, roll: Double, turn: Double, disc: CGFloat, glow: Double
    var jolt: CGSize = .zero

    /// How close it is, 0 far off to 1 at rest, for its floor shadow.
    var near: CGFloat { min(1, max(0, (scale - 0.22) / (Pose.rest.scale - 0.22))) }

    static let rest = Pose(x: -24, y: 0, scale: 1.2, tilt: 9, roll: 6, turn: 32, disc: 0.62, glow: 1)
    /// Far off to the right, tumbling, edge-on with its spine toward you.
    private static let start = Pose(x: 560, y: 120, scale: 0.22, tilt: 75, roll: -160, turn: 110, disc: 0, glow: 0)
    /// Still flying, nearly here.
    private static let near = Pose(x: 56, y: 10, scale: 1.12, tilt: 30, roll: -6, turn: 60, disc: 0.1, glow: 0.6)
    /// Caught: stopped dead, leaning a touch past where it settles.
    private static let caught = Pose(x: -24, y: 0, scale: 1.24, tilt: 11, roll: 8, turn: 36, disc: 0.66, glow: 1)

    static let caughtAt: Double = 0.82
    static let duration: Double = 1.5

    static func at(_ t: Double) -> Pose {
        var pose: Pose
        switch t {
        case ..<0.64: pose = mix(start, near, t / 0.64)
        case ..<caughtAt: pose = mix(near, caught, expo((t - 0.64) / (caughtAt - 0.64)))
        case ..<duration: pose = mix(caught, rest, softBack((t - caughtAt) / (duration - caughtAt)))
        default: return rest
        }
        // A two-frame jolt as it's caught.
        let k = t - caughtAt
        if k > 0, k < 0.16 {
            let fade = 1 - k / 0.16
            pose.jolt = CGSize(width: sin(k * 250) * fade * 4, height: cos(k * 300) * fade * 3)
        }
        return pose
    }

    private static func mix(_ a: Pose, _ b: Pose, _ p: Double) -> Pose {
        let q = CGFloat(p)
        return Pose(x: a.x + (b.x - a.x) * q, y: a.y + (b.y - a.y) * q, scale: a.scale + (b.scale - a.scale) * q,
                    tilt: a.tilt + (b.tilt - a.tilt) * p, roll: a.roll + (b.roll - a.roll) * p, turn: a.turn + (b.turn - a.turn) * p,
                    disc: a.disc + (b.disc - a.disc) * q, glow: a.glow + (b.glow - a.glow) * p)
    }

    private static func expo(_ t: Double) -> Double { t >= 1 ? 1 : 1 - pow(2, -10 * t) }

    private static func softBack(_ t: Double) -> Double {
        let c = 1.1, c3 = c + 1
        return 1 + c3 * pow(t - 1, 3) + c * pow(t - 1, 2)
    }
}

/// A quiet round icon button: a faint fill on hover, a press scale.
private struct PinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable(configuration: configuration)
    }

    private struct Hoverable: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}
