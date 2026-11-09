import SwiftUI

/// Where the onboarding case is and how it's turned: its offset from its
/// mark on the stage, how near it is (`zoom`), its tumble (`tilt` about the
/// horizontal, `roll` in the picture plane), which way it faces (`turn`, the
/// rack's own angle: positive shows the spine, 180 its back) and how far the
/// disc is slid out (a share of the case's size). Animatable as one value,
/// so `withAnimation` carries the whole case from mark to mark.
struct CasePose: VectorArithmetic {
    var x: Double = 0, y: Double = 0, zoom: Double = 1
    var tilt: Double = 0, roll: Double = 0, turn: Double = 0, disc: Double = 0

    /// Far off to the right, small and tumbling, edge-on: where a throw starts.
    static let offstage = CasePose(x: 900, y: 160, zoom: 0.2, tilt: 75, roll: -160, turn: 110, disc: 0)

    /// The case's mark on each track.
    static func mark(for track: OnboardingFlow.Track, branch: OnboardingFlow.Branch) -> CasePose {
        switch track {
        case .hello:
            // Coming back turns it round to its back: the backup side.
            CasePose(x: 0, y: 0, zoom: 1, tilt: 8, roll: -3, turn: branch == .new ? -26 : 154, disc: 0.3)
        case .look: CasePose(x: 14, y: 22, zoom: 0.96, tilt: 12, roll: 5, turn: 34, disc: 0)
        case .library: CasePose(x: -18, y: -12, zoom: 1.04, tilt: 6, roll: -4, turn: -20, disc: 0.55)
        case .restore: CasePose(x: 8, y: 10, zoom: 1, tilt: 10, roll: 3, turn: 22, disc: 0.2)
        case .spotify: CasePose(x: 10, y: 6, zoom: 0.98, tilt: 8, roll: -5, turn: -34, disc: 0.4)
        case .play: CasePose(x: -70, y: -6, zoom: 1.12, tilt: 9, roll: 6, turn: 30, disc: 0.48)
        }
    }

    // MARK: VectorArithmetic

    static var zero: CasePose { CasePose(x: 0, y: 0, zoom: 0, tilt: 0, roll: 0, turn: 0, disc: 0) }

    static func + (a: CasePose, b: CasePose) -> CasePose {
        CasePose(x: a.x + b.x, y: a.y + b.y, zoom: a.zoom + b.zoom, tilt: a.tilt + b.tilt,
                 roll: a.roll + b.roll, turn: a.turn + b.turn, disc: a.disc + b.disc)
    }

    static func - (a: CasePose, b: CasePose) -> CasePose {
        CasePose(x: a.x - b.x, y: a.y - b.y, zoom: a.zoom - b.zoom, tilt: a.tilt - b.tilt,
                 roll: a.roll - b.roll, turn: a.turn - b.turn, disc: a.disc - b.disc)
    }

    mutating func scale(by rhs: Double) {
        x *= rhs; y *= rhs; zoom *= rhs; tilt *= rhs; roll *= rhs; turn *= rhs; disc *= rhs
    }

    var magnitudeSquared: Double {
        x * x + y * y + zoom * zoom + tilt * tilt + roll * roll + turn * turn + disc * disc
    }
}

/// The jewel case that rides through onboarding: the rack's clear case, with
/// the FLACtastic mark on its insert until the library brings a cover, and a
/// disc behind it that slides out and spins. Each face is projected with its
/// own perspective matrix, as `RackBox` does, plus a back face so the case can
/// spin a full turn between tracks.
struct OnboardingCase: View, Animatable {
    var pose: CasePose
    let album: Album?
    let size: CGFloat
    let spin: Double
    /// Printed on the back insert: the tracklist.
    var backList: [String] = []

    nonisolated var animatableData: CasePose {
        get { pose }
        set { pose = newValue }
    }

    private var depth: CGFloat { (size * 0.078).rounded() }

    var body: some View {
        ZStack {
            // Its shadow on the floor below, growing as it comes near.
            EllipticalGradient(colors: [.black.opacity(0.5), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: size * 1.25, height: 46)
                .scaleEffect(x: 0.4 + 0.6 * near, y: 1)
                .opacity(0.75 * near)
                .offset(x: pose.x * 0.9, y: size * 0.72 + pose.y * 0.4)

            ZStack {
                // Behind every face: from the back it's inside the case,
                // showing only where it's slid out.
                disc
                if let face = face(width: depth, turnedBy: -90, out: size / 2) {
                    spine.overlay(Color.black.opacity(face.shade)).projectionEffect(face.transform).zIndex(1)
                }
                if let face = face(width: depth, turnedBy: 90, out: size / 2) {
                    edge.overlay(Color.black.opacity(face.shade)).projectionEffect(face.transform).zIndex(1)
                }
                if let face = face(width: size, turnedBy: 180, out: depth / 2) {
                    back.overlay(Color.black.opacity(face.shade)).projectionEffect(face.transform).zIndex(2)
                }
                if let face = face(width: size, turnedBy: 0, out: depth / 2) {
                    front.overlay(Color.black.opacity(face.shade)).projectionEffect(face.transform).zIndex(2)
                }
            }
            .frame(width: size, height: size)
            .rotation3DEffect(.degrees(pose.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .rotationEffect(.degrees(pose.roll))
            .scaleEffect(pose.zoom)
            .offset(x: pose.x, y: pose.y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var near: Double { min(1, max(0, (pose.zoom - 0.2) / 0.8)) }

    /// A face `width` wide, turned `turnedBy`° from the front and standing
    /// `out` from the box's centre (`slide` along its width): its projection
    /// and how much it's shaded, or nil while it faces away.
    private func face(width: CGFloat, turnedBy: Double, out: CGFloat, slide: CGFloat = 0, always: Bool = false) -> (transform: ProjectionTransform, shade: Double)? {
        let total = (pose.turn + turnedBy) * .pi / 180
        guard always || cos(total) > 0.001 else { return nil }
        var rotation = CATransform3DIdentity
        rotation.m11 = cos(total); rotation.m13 = -sin(total)
        rotation.m31 = sin(total); rotation.m33 = cos(total)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (size * 3.2)
        var t = CATransform3DMakeTranslation(-width / 2 + slide, -size / 2, out)
        t = CATransform3DConcat(t, rotation)
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(width / 2, size / 2, 0))
        return (ProjectionTransform(t), (1 - abs(cos(total))) * 0.45)
    }

    // MARK: Faces

    private var disc: some View {
        let diameter = (size * 0.92).rounded()
        let a = pose.turn * .pi / 180
        var rotation = CATransform3DIdentity
        rotation.m11 = cos(a); rotation.m13 = -sin(a)
        rotation.m31 = sin(a); rotation.m33 = cos(a)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (size * 3.2)
        var t = CATransform3DMakeTranslation(-diameter / 2 + pose.disc * size, -diameter / 2, -depth / 2 - 1)
        t = CATransform3DConcat(t, rotation)
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(diameter / 2, diameter / 2, 0))
        return OnboardingDisc(album: album, diameter: diameter, spin: spin)
            .projectionEffect(ProjectionTransform(t))
    }

    /// The cover under a clear lid, as the rack's clear case draws it: the
    /// insert just inside the plastic, a ridged hinge down the left, a gloss
    /// and a bright rim. Before there's a cover, the insert is the F mark.
    private var front: some View {
        let inset = max(3, size * 0.017)
        let hinge = max(12, size * 0.067)
        return ZStack(alignment: .topLeading) {
            Color(white: 0.07)
            ZStack {
                MarkInsert(size: size - hinge - inset)
                if let album, album.artwork != nil {
                    ArtworkView(data: album.artwork, size: size - hinge - inset, id: "album:\(album.id)", showsShadow: false, alwaysSquare: true)
                        .transition(.opacity.combined(with: .scale(scale: 1.1)))
                }
            }
            .frame(width: size - hinge - inset, height: size - inset * 2)
            .clipped()
            .offset(x: hinge, y: inset)
            .animation(.easeOut(duration: 0.9), value: album?.id)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.16), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.3),
                    .init(color: .white.opacity(0.1), location: 0.34),
                    .init(color: .white.opacity(0.03), location: 0.38),
                    .init(color: .white.opacity(0.12), location: 0.7),
                    .init(color: .white.opacity(0.02), location: 0.74),
                    .init(color: .black.opacity(0.25), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: hinge, height: size)
            LinearGradient(
                stops: [.init(color: .white.opacity(0.2), location: 0), .init(color: .clear, location: 0.32),
                        .init(color: .clear, location: 0.7), .init(color: .white.opacity(0.07), location: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
    }

    /// The case from behind: the back insert, printed with the tracklist.
    private var back: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.045)
            VStack(alignment: .leading, spacing: size * 0.035) {
                ForEach(Array(backList.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: size * 0.062, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                }
                Spacer(minLength: 0)
                BrandMark(height: size * 0.07, color: .white.opacity(0.5))
            }
            .padding(size * 0.1)
        }
        .frame(width: size, height: size)
        .overlay(Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    private var spine: some View {
        ZStack {
            Color(white: 0.07)
            VStack {
                spineText("FLACTASTIC", weight: .heavy, opacity: 1)
                Spacer()
                spineText((album?.name ?? "Setup").uppercased(), weight: .semibold, opacity: 0.7)
            }
            .padding(.vertical, 12)
        }
        .frame(width: depth, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }

    private func spineText(_ text: String, weight: Font.Weight, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: max(7, depth * 0.48), weight: weight))
            .tracking(0.8)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(opacity))
            .fixedSize()
            .frame(width: size * 0.42, alignment: .center)
            .rotationEffect(.degrees(90))
            .frame(width: depth, height: size * 0.42)
    }

    private var edge: some View {
        ZStack {
            Color(white: 0.09)
            LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: depth, height: size)
        .overlay(Rectangle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// The insert before there's music: the F mark on dark card.
private struct MarkInsert: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(white: 0.15), Color(white: 0.04)], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: size)
            BrandMark(height: size * 0.3, color: .white.opacity(0.92))
        }
        .frame(width: size, height: size)
    }
}

/// The disc: the album's own (the rack's `RackDisc`) once there is one, a
/// plain silver pressing before. Turns at `spin` degrees a second, keeping
/// its angle when the speed changes.
struct OnboardingDisc: View {
    let album: Album?
    let diameter: CGFloat
    let spin: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = SpinClock()

    var body: some View {
        TimelineView(.animation(paused: spin == 0 || reduceMotion)) { context in
            pressing
                .rotationEffect(.degrees(clock.angle(at: context.date, speed: reduceMotion ? 0 : spin)))
        }
    }

    @ViewBuilder
    private var pressing: some View {
        if let album {
            RackDisc(album: album, colors: RackDisc.colors(for: album), diameter: diameter, isSpinning: false, castsShadow: false)
        } else {
            ZStack {
                Circle().fill(AngularGradient(
                    colors: [Color(white: 0.85), Color(white: 0.96), Color(red: 0.75, green: 0.9, blue: 1),
                             Color(red: 0.91, green: 0.82, blue: 1), Color(red: 1, green: 0.9, blue: 0.77),
                             Color(white: 0.85), Color(white: 0.96), Color(red: 0.79, green: 0.95, blue: 0.9),
                             Color(white: 0.88), Color(white: 0.85)],
                    center: .center, angle: .degrees(30)))
                Circle()
                    .strokeBorder(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.07)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: diameter * 0.4),
                                  lineWidth: diameter * 0.22)
                    .frame(width: diameter * 0.64, height: diameter * 0.64)
                AngularGradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                                center: .center, angle: .degrees(140))
                    .clipShape(Circle())
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1).frame(width: diameter * 0.165, height: diameter * 0.165)
                Circle().fill(Theme.background).frame(width: diameter * 0.075, height: diameter * 0.075)
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)
            }
            .frame(width: diameter, height: diameter)
            .drawingGroup()
        }
    }
}

/// Integrates the disc's angle over time, so a change of speed doesn't jump it.
@MainActor
private final class SpinClock {
    private var angle: Double = 0
    private var last: Date?

    func angle(at date: Date, speed: Double) -> Double {
        if let last { angle = (angle + speed * min(0.1, date.timeIntervalSince(last))).truncatingRemainder(dividingBy: 360) }
        last = date
        return angle
    }
}
