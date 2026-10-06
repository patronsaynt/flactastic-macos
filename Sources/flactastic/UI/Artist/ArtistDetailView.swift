import SwiftUI
import AppKit

struct ArtistDetailView: View {
    let artistKey: String

    @Environment(LibraryStore.self)        private var library
    @Environment(ArtistStore.self)         private var artistStore
    @Environment(ArtistRemoteCache.self)   private var artistRemoteCache
    @Environment(ArtistImageFetcher.self)  private var artistImageFetcher
    @Environment(PlayerState.self)         private var player
    @Environment(Settings.self)            private var settings
    @Environment(NavigationRouter.self)    private var router
    @Environment(\.colorScheme)            private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isEditing = false
    /// Decoded banner/profile images and the light-mode tint, rebuilt only
    /// when the underlying image data changes rather than on every render.
    @State private var art = HeroArt()
    /// Drives the entrance: the page zooms in from blurred, then the hero
    /// elements arrive in sequence.
    @State private var hasEntered = false
    @State private var showsCompactHeader = false
    /// The artist's summary, built once and rebuilt only when the library or
    /// the artist overrides change. Building it walks the whole library, so
    /// it must not run on every redraw (scrolling redraws the page).
    @State private var cachedSummary: ArtistSummary?

    private nonisolated static let scrollSpace = "artistScroll"
    private static let discographyID = "discography"
    /// Scroll distance before the floating player bar comes back.
    private static let playerRevealOffset: CGFloat = 140

    private func popDetail() {
        router.goBackInCollection()
    }

    private var summary: ArtistSummary? {
        if let cachedSummary, cachedSummary.id == artistKey { return cachedSummary }
        return buildSummary()
    }

    private func buildSummary() -> ArtistSummary? {
        library.artist(
            forKey: artistKey,
            resolver: library.makeArtistResolver(),
            overrides: artistStore.overrides
        )
    }

    private func refreshSummary() {
        cachedSummary = buildSummary()
    }

    private var isLight: Bool { colorScheme == .light }

    /// Reduce Motion or the app's own fade setting swaps the choreography for
    /// plain fades.
    private var calmMotion: Bool { reduceMotion || !settings.fadeAnimationsEnabled }

    var body: some View {
        if let summary {
            GeometryReader { geo in
                let heroHeight = max(geo.size.height, 520)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            hero(summary, height: heroHeight, proxy: proxy)
                                .onGeometryChange(for: CGFloat.self) { geometry in
                                    -geometry.frame(in: .named(Self.scrollSpace)).minY
                                } action: { offset in
                                    handleScroll(offset: offset, heroHeight: heroHeight)
                                }

                            ArtistDiscographyView(
                                summary: summary,
                                width: geo.size.width,
                                viewportHeight: geo.size.height,
                                scrollSpace: Self.scrollSpace,
                                bannerWash: isLight ? lightWash : nil
                            )
                            .id(Self.discographyID)
                        }
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
                    .blur(radius: hasEntered || calmMotion ? 0 : 28)
                    .opacity(hasEntered ? 1 : 0)
                }
                .overlay(alignment: .top) {
                    if showsCompactHeader {
                        compactHeader(summary)
                            .transition(.opacity.combined(with: .offset(y: -10)))
                    }
                }
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32), value: showsCompactHeader)
            }
            .background(Theme.background)
            .onAppear {
                if cachedSummary?.id != artistKey { cachedSummary = summary }
                router.hidesPlayerBar = true
                withAnimation(calmMotion
                              ? .easeOut(duration: 0.3)
                              : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1)) {
                    hasEntered = true
                }
            }
            .onDisappear { router.hidesPlayerBar = false }
            .onChange(of: library.tracksRevision) { refreshSummary() }
            .onChange(of: artistStore.revision) { refreshSummary() }
            .onChange(of: artistKey) { refreshSummary() }
            .task(id: summary.id) {
                if settings.autoFetchArtistImages {
                    artistImageFetcher.ensureImage(
                        forKey: summary.id,
                        displayName: summary.displayName
                    )
                }
            }
            .task(id: heroSourceID(summary)) {
                art = await HeroArt.load(heroSources(summary))
            }
            .sheet(isPresented: $isEditing) {
                ArtistEditorView(
                    canonicalKey: summary.id,
                    fallbackName: summary.displayName,
                    fallbackArtwork: summary.artworkSample
                )
                .environment(artistStore)
            }
        } else {
            Text("Artist not found")
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
    }

    /// Only flips state when a threshold is crossed, so scrolling doesn't
    /// re-render the page every frame.
    private func handleScroll(offset: CGFloat, heroHeight: CGFloat) {
        let hidePlayer = offset < Self.playerRevealOffset
        if router.hidesPlayerBar != hidePlayer { router.hidesPlayerBar = hidePlayer }
        let compact = offset > heroHeight - 60
        if showsCompactHeader != compact { showsCompactHeader = compact }
    }

    // MARK: - Image sources

    private struct HeroSources: Sendable {
        var banner: Data?
        /// User-supplied banner. Anything else (remote profile pic, album-art
        /// sample) is blurred as a backdrop.
        var isTrueBanner: Bool
        var profile: Data?
    }

    private func heroSources(_ summary: ArtistSummary) -> HeroSources {
        let override = artistStore.override(forKey: summary.id)
        let remoteImage = artistRemoteCache.entry(forKey: summary.id)?.profileImage
        let banner = override?.bannerImage ?? remoteImage ?? summary.artworkSample
        return HeroSources(
            banner: banner,
            isTrueBanner: override?.bannerImage != nil,
            profile: override?.profileImage ?? remoteImage ?? banner
        )
    }

    private func heroSourceID(_ summary: ArtistSummary) -> String {
        let s = heroSources(summary)
        return "\(summary.id)|\(s.banner?.count ?? 0)|\(s.profile?.count ?? 0)|\(s.isTrueBanner)"
    }

    /// The hero's images, prepared off the main thread: decoded at display
    /// size rather than full resolution, with every blur baked in ahead of
    /// time so nothing blurs live while the page scrolls.
    ///
    /// `NSImage` isn't formally `Sendable`; these are created once, never
    /// mutated, and only read afterward, which is the whole of the claim.
    private struct HeroArt: @unchecked Sendable {
        /// The banner as drawn. Banners the user set are sharp; a stand-in
        /// (fetched photo, album art) comes pre-blurred as a backdrop.
        var banner: NSImage?
        /// A heavily blurred copy for the bottom fade into the page.
        var softBanner: NSImage?
        var profile: NSImage?
        /// The banner's dominant hue, for light mode's tint.
        var swatch: HomePalette.Swatch?

        init() {}

        static func load(_ sources: HeroSources) async -> HeroArt {
            await Task.detached(priority: .userInitiated) {
                var art = HeroArt()
                if let data = sources.banner {
                    if sources.isTrueBanner {
                        art.banner = PrerenderedImage.nsImage(PrerenderedImage.downsampled(data, maxPixel: 2880))
                    } else {
                        art.banner = PrerenderedImage.nsImage(PrerenderedImage.blurred(
                            data, maxPixel: 640,
                            radius: PrerenderedImage.pixelRadius(points: 30, maxPixel: 640)
                        ))
                    }
                    art.softBanner = PrerenderedImage.nsImage(PrerenderedImage.blurred(
                        data, maxPixel: 480,
                        radius: PrerenderedImage.pixelRadius(points: sources.isTrueBanner ? 36 : 66, maxPixel: 480)
                    ))
                    art.swatch = HomePalette.extract(from: data)?.swatches.first
                }
                if let data = sources.profile {
                    // Drawn at 200pt; 512px covers it at 2x.
                    art.profile = PrerenderedImage.nsImage(PrerenderedImage.downsampled(data, maxPixel: 512))
                }
                return art
            }.value
        }
    }

    // MARK: - Hero

    private var ink: Color { isLight ? Theme.textPrimary : .white }
    private var inkSecondary: Color { isLight ? Color(white: 0.28) : .white.opacity(0.88) }
    private var lightWash: Color { art.swatch.map(Self.lightTint(for:)) ?? Theme.background }

    private func hero(_ summary: ArtistSummary, height: CGFloat, proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottomLeading) {
            bannerLayer(art.banner, height: height)
                .scaleEffect(hasEntered || calmMotion ? 1 : 1.14)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.9), value: hasEntered)

            // Readability for the back button against bright image tops.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .frame(maxHeight: .infinity, alignment: .top)

            if isLight {
                lightFade(height: height)
            } else {
                darkFade(height: height)
            }

            heroContent(summary)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.bottom, isLight ? 72 : 112)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .visualEffect { content, geometry in
                    let scrolled = max(0, -geometry.frame(in: .scrollView).minY)
                    return content
                        .opacity(max(0, 1 - scrolled / 460))
                        .offset(y: -scrolled * 0.2)
                }

            discographyCue(proxy: proxy)
                .padding(.bottom, Theme.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .visualEffect { content, geometry in
                    let scrolled = max(0, -geometry.frame(in: .scrollView).minY)
                    return content.opacity(max(0, 1 - scrolled / 80))
                }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(isLight ? lightWash : Theme.background)
        .clipped()
        .overlay(alignment: .topLeading) {
            HeroBackButton(action: popDetail)
                .padding(.leading, Theme.Spacing.xxl)
                .padding(.top, Theme.Spacing.xl)
                .opacity(hasEntered ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(calmMotion ? 0 : 0.15), value: hasEntered)
        }
    }

    /// The banner image, moving at half the scroll speed with a slight zoom.
    private func bannerLayer(_ image: NSImage?, height: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.surfaceElevated
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .visualEffect { content, geometry in
                let scrolled = max(0, -geometry.frame(in: .scrollView).minY)
                return content
                    .offset(y: scrolled * 0.5)
                    .scaleEffect(1 + scrolled * 0.00035, anchor: .top)
            }
            .frame(height: height, alignment: .top)
            .clipped()
    }

    /// Dark mode: the image darkens, then blurs progressively into the black
    /// background the discography sits on.
    private func darkFade(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0.37),
                    .init(color: .black.opacity(0.55), location: 0.68),
                ],
                startPoint: .top, endPoint: .bottom
            )
            bannerLayer(art.softBanner, height: height)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 360)
                }
            LinearGradient(
                stops: [
                    .init(color: Theme.background.opacity(0), location: 0),
                    .init(color: Theme.background, location: 0.94),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 280)
        }
    }

    /// Light mode: the lower half frosts into a pale wash of the banner's own
    /// color, and the name and controls switch to dark ink on top of it.
    private func lightFade(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            bannerLayer(art.softBanner, height: height)
                .saturation(1.25)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 520)
                }
            LinearGradient(
                stops: [
                    .init(color: lightWash.opacity(0), location: 0),
                    .init(color: lightWash.opacity(0.9), location: 0.42),
                    .init(color: lightWash, location: 0.66),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 520)
        }
    }

    private func heroContent(_ summary: ArtistSummary) -> some View {
        let arrive = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)

        return HStack(alignment: .bottom, spacing: Theme.Spacing.xxl) {
            profileCircle(size: 200)
                .overlay(Circle().strokeBorder(isLight ? .white : .white.opacity(0.9), lineWidth: 4))
                .shadow(color: .black.opacity(isLight ? 0.22 : 0.5), radius: 22, y: 20)
                .scaleEffect(hasEntered || calmMotion ? 1 : 0.86)
                .opacity(hasEntered ? 1 : 0)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(calmMotion ? 0 : 0.22), value: hasEntered)

            VStack(alignment: .leading, spacing: 0) {
                // The name rises out of its own line, clipped like a reveal.
                Text(summary.displayName)
                    .font(.system(size: 112, weight: .heavy))
                    .tracking(-4.5)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .offset(y: hasEntered || calmMotion ? 0 : 140)
                    .padding(.bottom, 8)
                    .clipped()
                    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.95).delay(calmMotion ? 0 : 0.32), value: hasEntered)

                Text(headerSubtitle(summary))
                    .font(.system(size: 14))
                    .foregroundStyle(inkSecondary)
                    .padding(.top, 6)
                    .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.52))

                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        playAll(summary, shuffle: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(HeroPillStyle(kind: .primary, ink: ink, isLight: isLight))

                    Button {
                        playAll(summary, shuffle: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
                }
                .padding(.top, Theme.Spacing.xl)
                .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.62))
            }

            Spacer(minLength: 0)

            Button { isEditing = true } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(HeroPillStyle(kind: .secondary, ink: ink, isLight: isLight))
            .arrival(hasEntered, calm: calmMotion, animation: arrive.delay(0.72))
        }
    }

    @ViewBuilder
    private func profileCircle(size: CGFloat) -> some View {
        Group {
            if let image = art.profile {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.surfaceElevated
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func discographyCue(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)) {
                proxy.scrollTo(Self.discographyID, anchor: .top)
            }
        } label: {
            VStack(spacing: 2) {
                Text("Discography")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .phaseAnimator(calmMotion ? [0] : [0, 4]) { content, dy in
                        content.offset(y: dy)
                    } animation: { _ in .easeInOut(duration: 1.2) }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to discography")
        .opacity(hasEntered ? 1 : 0)
        .animation(.easeOut(duration: 0.8).delay(calmMotion ? 0 : 1.15), value: hasEntered)
    }

    private func headerSubtitle(_ s: ArtistSummary) -> String {
        let releases = s.albums.count + s.singles.count
        var parts: [String] = []
        if releases > 0 { parts.append("\(releases) release\(releases == 1 ? "" : "s")") }
        if !s.appearsOn.isEmpty { parts.append("\(s.appearsOn.count) appearance\(s.appearsOn.count == 1 ? "" : "s")") }
        parts.append("\(s.trackCount) track\(s.trackCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Compact header

    /// Fades in once the hero has scrolled away: two small frosted pills
    /// floating over the page, identity on the left and playback on the
    /// right, with the content showing through between them.
    private func compactHeader(_ summary: ArtistSummary) -> some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Button(action: popDetail) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.textPrimary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                profileCircle(size: 28)
                Text(summary.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .frame(height: 42)
            .floatingGlass()

            Spacer(minLength: Theme.Spacing.lg)

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    playAll(summary, shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(HeroPillStyle(kind: .secondary, ink: Theme.textPrimary, isLight: isLight, compact: true))
                Button {
                    playAll(summary, shuffle: false)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(HeroPillStyle(kind: .primary, ink: Theme.textPrimary, isLight: isLight, compact: true))
            }
            .padding(5)
            .floatingGlass()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 14)
    }

    // MARK: - Actions

    private func playAll(_ summary: ArtistSummary, shuffle: Bool) {
        let tracks = (summary.albums + summary.singles + summary.appearsOn)
            .flatMap(\.tracks)
        guard !tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let startIndex = shuffle ? Int.random(in: 0..<tracks.count) : 0
        player.startFreshQueue(tracks, startAt: startIndex, source: summary.displayName)
        player.engine.play()
    }

    // MARK: - Colour

    /// A pale wash of the banner's dominant hue for the light-mode hero fade.
    static func lightTint(for swatch: HomePalette.Swatch) -> Color {
        Color(nsColor: NSColor(hue: swatch.hue, saturation: 0.1, brightness: 0.955, alpha: 1))
    }

    /// Cheaply samples the artwork at 8×8 and averages the pixels for a
    /// banner gradient base. Returns nil for missing or invalid data.
    static func dominantColor(from data: Data?) -> Color? {
        guard let data, let nsImage = NSImage(data: data),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        let target: Int = 8
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: target, pixelsHigh: target,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        )
        guard let rep else { return nil }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            bitmap.draw(in: NSRect(x: 0, y: 0, width: target, height: target))
        }
        NSGraphicsContext.restoreGraphicsState()

        var rTotal = 0, gTotal = 0, bTotal = 0, count = 0
        for x in 0..<target {
            for y in 0..<target {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                rTotal += Int(color.redComponent * 255)
                gTotal += Int(color.greenComponent * 255)
                bTotal += Int(color.blueComponent * 255)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Color(
            red: Double(rTotal / count) / 255.0,
            green: Double(gTotal / count) / 255.0,
            blue: Double(bTotal / count) / 255.0
        )
    }
}

private extension View {
    /// Frosted capsule that floats over content: material, a hairline edge
    /// and a soft drop shadow so it separates from whatever scrolls beneath.
    func floatingGlass() -> some View {
        self
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    /// Fades and lifts into place when `active` flips, after the hero zoom.
    func arrival(_ active: Bool, calm: Bool, animation: Animation) -> some View {
        self
            .opacity(active ? 1 : 0)
            .offset(y: active || calm ? 0 : 16)
            .animation(calm ? .easeOut(duration: 0.3) : animation, value: active)
    }
}
