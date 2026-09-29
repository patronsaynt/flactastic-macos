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

    @State private var isEditing = false

    private func popDetail() {
        router.goBackInCollection()
    }

    private var summary: ArtistSummary? {
        let resolver = library.makeArtistResolver()
        return library.artist(
            forKey: artistKey,
            resolver: resolver,
            overrides: artistStore.overrides
        )
    }

    var body: some View {
        if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    banner(summary)
                    section("Albums", albums: summary.albums)
                    section("Singles & EPs", albums: summary.singles)
                    section("Appears On", albums: summary.appearsOn)
                }
                .padding(.bottom, 100)
            }
            .background(Theme.background)
            .overlay(alignment: .topLeading) {
                DetailBackButton { popDetail() }
                    .padding(.leading, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.lg)
            }
            .task(id: summary.id) {
                if settings.autoFetchArtistImages {
                    artistImageFetcher.ensureImage(
                        forKey: summary.id,
                        displayName: summary.displayName
                    )
                }
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

    // MARK: - Banner

    private func banner(_ summary: ArtistSummary) -> some View {
        let override = artistStore.override(forKey: summary.id)
        let remoteImage = artistRemoteCache.entry(forKey: summary.id)?.profileImage
        // True banner = user-supplied bannerImage. Anything else (remote
        // profile pic, album-art sample) gets blurred as a backdrop.
        let isTrueBanner = override?.bannerImage != nil
        let bannerData = override?.bannerImage ?? remoteImage ?? summary.artworkSample
        let baseColor = ArtistDetailView.dominantColor(from: bannerData) ?? Theme.surfaceElevated

        return ZStack(alignment: .bottomLeading) {
            // Background image or solid colour fallback
            Group {
                if let data = bannerData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: isTrueBanner ? 0 : 30)
                } else {
                    baseColor
                }
            }
            .frame(height: 320)
            .clipped()

            // Gradient fade to background
            LinearGradient(
                colors: [
                    baseColor.opacity(0.0),
                    baseColor.opacity(0.4),
                    Theme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)

            // Foreground text + actions
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("ARTIST")
                        .font(Theme.Font.caption)
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(summary.displayName)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    Text(headerSubtitle(summary))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.white.opacity(0.85))

                    HStack(spacing: Theme.Spacing.md) {
                        Button {
                            playAll(summary, shuffle: false)
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "play.fill")
                                Text("Play")
                            }
                        }
                        .buttonStyle(PillButtonStyle(isPrimary: true))

                        Button {
                            playAll(summary, shuffle: true)
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "shuffle")
                                Text("Shuffle")
                            }
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
                Spacer()
                Button { isEditing = true } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "pencil")
                        Text("Edit")
                    }
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .frame(height: 320)
    }

    private func headerSubtitle(_ s: ArtistSummary) -> String {
        let releases = s.albums.count + s.singles.count
        var parts: [String] = []
        if releases > 0 { parts.append("\(releases) release\(releases == 1 ? "" : "s")") }
        if !s.appearsOn.isEmpty { parts.append("\(s.appearsOn.count) appearance\(s.appearsOn.count == 1 ? "" : "s")") }
        parts.append("\(s.trackCount) track\(s.trackCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ title: String, albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: Theme.Spacing.lg)],
                    spacing: Theme.Spacing.xl
                ) {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                        Button { router.collectionPath.append(album.id) } label: {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                        .riseFadeIn(index: index)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
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

    // MARK: - Dominant colour

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
