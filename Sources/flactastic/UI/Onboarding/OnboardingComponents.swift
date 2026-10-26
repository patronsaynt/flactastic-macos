import SwiftUI

/// A step's title and the line under it, set large on the stage.
struct OnboardingStepText: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 64, weight: .heavy))
                .tracking(-2.4)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .frame(maxWidth: 500, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The stage's ground: the first album cover in the library, blurred past
/// detail and darkened (lightened in light mode), fading out toward the
/// left where the words sit. Before a library is linked it's the plain
/// background; covers fade in once the scan finds them.
struct OnboardingBackdrop: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        // The image is an overlay on the background color, so it takes the
        // window's size. As a plain ZStack child, a square cover filling a
        // wide window came out taller than the window, grew the whole stage
        // and pushed the words off the top.
        Theme.background
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .saturation(1.3)
                        .brightness(colorScheme == .light ? 0.2 : -0.3)
                        .opacity(colorScheme == .light ? 0.55 : 1)
                        .transition(.opacity)
                }
            }
            .clipped()
            .overlay(LinearGradient(
                stops: [.init(color: Theme.background, location: 0.3), .init(color: Theme.background.opacity(0), location: 0.75)],
                startPoint: .leading, endPoint: .trailing
            ))
            .allowsHitTesting(false)
        .task(id: library.albums.first(where: { $0.artwork != nil })?.id) {
            guard let data = library.albums.first(where: { $0.artwork != nil })?.artwork else { return }
            let id = "onboarding:\(ArtworkImageCache.contentID(for: data))"
            let box = await BlurredArtworkCache.shared.image(for: data, id: id)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.2)) { image = box.image }
        }
    }
}

/// Three album covers fanned out on the right of the stage: the user's own
/// once their library is linked, quiet placeholder sleeves until then.
struct OnboardingCoverFan: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spread = false

    var body: some View {
        let covers = Array(library.albums.filter { $0.artwork != nil }.prefix(3))
        GeometryReader { geo in
            let size = min(260, geo.size.width * 0.58)
            ZStack {
                ForEach(0..<3, id: \.self) { slot in
                    sleeve(slot < covers.count ? covers[slot] : nil, slot: slot, size: size)
                        .rotationEffect(.degrees(spread ? [-9.0, 7.0, 0][slot] : 0))
                        .offset(x: spread ? [-90.0, 90.0, 0][slot] : 0, y: spread ? [20.0, 10.0, 0][slot] : 0)
                        .zIndex(Double(slot))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(0.2)) { spread = true }
        }
    }

    @ViewBuilder
    private func sleeve(_ album: Album?, slot: Int, size: CGFloat) -> some View {
        Group {
            if let album {
                ArtworkView(data: album.artwork, size: size, id: "album:\(album.id)", showsShadow: false)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: [0.16, 0.12, 0.2][slot]), Color(white: [0.07, 0.05, 0.09][slot])],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(alignment: .bottomTrailing) {
                        // A record peeking from the sleeve's corner.
                        Circle()
                            .fill(Color(white: 0.04))
                            .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1).padding(size * 0.08))
                            .overlay(Circle().fill(Color(white: 0.2)).frame(width: size * 0.18, height: size * 0.18))
                            .frame(width: size * 0.5, height: size * 0.5)
                            .offset(x: size * 0.12, y: size * 0.12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 24)
        .animation(.easeOut(duration: 0.6), value: album?.id)
    }
}

/// Small "Optional" tag above the Spotify step's title.
struct OnboardingOptionalTag: View {
    var body: some View {
        Text("OPTIONAL")
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
    }
}

/// A rounded row on the stage: an icon, a title and a detail line, with an
/// accessory on the right. The linked library and the Spotify account.
struct OnboardingStatusRow<Icon: View, Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
        .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
