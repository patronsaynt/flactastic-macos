import SwiftUI
import AppKit

/// The Collection tab's album rack: every album as a CD spine, side by side
/// on one long shelf that scrolls sideways (wheel or trackpad, either axis). Each spine carries a blurred slice of its album's art under clear
/// plastic, with the title and artist printed down it; a small tab above the
/// first spine of each group marks where the sort's groups begin (letters,
/// years or genres). Hovering a spine lifts it, and the album's details show
/// under the shelf.
///
/// Clicking a spine takes the case out: the rack falls back, the case lifts
/// from its slot and turns from its spine to its front cover, the disc slides
/// out to the right, and the album's details appear with Play and Open. Back
/// (or Esc) reverses it and returns the case to its slot.
///
/// Built for smooth scrolling: spines sit at fixed positions in one container
/// that slides, so scrolling moves a single transform; only spines near the
/// window are built; each spine's blurred art is rendered once off the main
/// thread and reused; nothing is masked or blurred live while it scrolls (the
/// rack only blurs behind a case taken out); the ends fade with
/// gradients painted over the rack rather than a mask.
struct AlbumRackView: View {
    /// Already sorted and filtered by the Collection page.
    let albums: [Album]
    let sort: CollectionSortOption
    /// The space the page has for the rack.
    let available: CGSize
    let open: (Album) -> Void
    let contextMenu: (Album) -> [FLContextMenuItem]

    @Environment(PlayerState.self) private var player
    @Environment(ListeningStore.self) private var listening
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// How far the rack is scrolled, in points.
    @State private var scrollX: CGFloat = 0
    @State private var hoveredID: String?
    /// The album the readout under the shelf shows: the last one hovered, so
    /// it doesn't blink out as the pointer crosses a gap.
    @State private var readoutID: String?
    @State private var cachedLayout = RackLayout()

    // The case taken out of the rack.
    @State private var takenOut: Album?
    /// Where its spine sat, in the rack's coordinates, so it can go back.
    @State private var takenFrom: CGRect = .zero
    /// 0 on the shelf, edge-on; 1 out, front on.
    @State private var isOut = false
    @State private var closeTask: Task<Void, Never>?

    private var metrics: RackMetrics { RackMetrics(available: available) }

    private var layoutKey: RackLayout.Key {
        RackLayout.Key(albums: albums.map(\.id), sort: sort, metrics: metrics)
    }

    private var layout: RackLayout {
        cachedLayout.key == layoutKey ? cachedLayout : RackLayout(albums: albums, sort: sort, metrics: metrics)
    }

    var body: some View {
        let metrics = metrics
        let layout = layout
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                rack(metrics, layout: layout)
                readout(metrics, layout: layout)
            }
                .blur(radius: isOut && !reduceMotion ? 10 : 0)
                .opacity(isOut ? 0.16 : 1)
                .scaleEffect(isOut ? 0.96 : 1, anchor: .center)
                // Falls back as the case comes out; comes forward again only
                // once the case is nearly home.
                .animation(isOut ? .easeOut(duration: 0.5) : .easeOut(duration: 0.45).delay(0.6), value: isOut)
                .allowsHitTesting(takenOut == nil)

            if let album = takenOut {
                caseStage(album, metrics: metrics)
            }
        }
        .frame(width: available.width, height: available.height, alignment: .topLeading)
        .onChange(of: layoutKey, initial: true) {
            cachedLayout = RackLayout(albums: albums, sort: sort, metrics: metrics)
            scrollX = clampedScroll(scrollX, layout: cachedLayout)
        }
    }

    // MARK: - Rack

    private func rack(_ metrics: RackMetrics, layout: RackLayout) -> some View {
        let visible = layout.visibleRange(from: scrollX - metrics.spineWidth * 2, to: scrollX + available.width)
        return ZStack(alignment: .topLeading) {
            // Everything inside slides together with one offset.
            ZStack(alignment: .topLeading) {
                ForEach(layout.tabs.filter { visible.contains($0.firstIndex) }) { tab in
                    RackTab(label: tab.label)
                        .offset(x: layout.x(of: tab.firstIndex), y: metrics.top - RackTab.height - 2)
                }
                ForEach(visible, id: \.self) { index in
                    let album = layout.albums[index]
                    let credit = layout.credits[index]
                    let hovered = hoveredID == album.id
                    RackSpine(
                        album: album,
                        credit: credit,
                        width: metrics.spineWidth,
                        height: metrics.spineHeight,
                        isHovered: hovered
                    )
                    .equatable()
                    .offset(
                        x: layout.x(of: index),
                        y: metrics.top - (hovered ? metrics.hoverLift : 0)
                    )
                    .zIndex(hovered ? 1 : 0)
                    .opacity(takenOut?.id == album.id ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(album.name), \(credit)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { takeOut(album, at: spineFrame(index, layout: layout, metrics: metrics)) }
                }
            }
            .offset(x: collectionGutter - scrollX)
            .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: hoveredID)

            edgeFades
        }
        .frame(width: available.width, height: metrics.top + metrics.spineHeight + 30, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        // The spine under the pointer is worked out from the pointer's
        // position: spines are placed by offset, and per-spine hover areas
        // stay where the spines were laid out, not where they're drawn.
        .onContinuousHover(coordinateSpace: .local) { phase in
            let id: String?
            switch phase {
            case .active(let point): id = spineIndex(at: point, layout: layout, metrics: metrics).map { layout.albums[$0].id }
            case .ended: id = nil
            }
            if id != hoveredID { hoveredID = id }
            if let id, id != readoutID { readoutID = id }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            guard let index = spineIndex(at: point, layout: layout, metrics: metrics) else { return }
            takeOut(layout.albums[index], at: spineFrame(index, layout: layout, metrics: metrics))
        }
        .help(hoveredID.flatMap { id in layout.albums.firstIndex { $0.id == id } }.map { "\(layout.albums[$0].name) — \(layout.credits[$0])" } ?? "")
        .flContextMenu {
            guard let id = hoveredID, let album = layout.albums.first(where: { $0.id == id }) else { return [] }
            return contextMenu(album)
        }
        .background {
            RackScrollCatcher { delta in
                scrollX = clampedScroll(scrollX + delta, layout: layout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Album rack")
    }

    /// Soft ends in the page colour, painted over the rack so the spines
    /// fade out at both sides as they scroll past.
    private var edgeFades: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [Theme.background, Theme.background.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 72)
            Spacer(minLength: 0)
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .leading, endPoint: .trailing)
                .frame(width: 96)
        }
        .allowsHitTesting(false)
    }

    /// The spine under `point` (in the rack's own coordinates), if any.
    private func spineIndex(at point: CGPoint, layout: RackLayout, metrics: RackMetrics) -> Int? {
        guard point.y >= metrics.top - metrics.hoverLift, point.y <= metrics.top + metrics.spineHeight else { return nil }
        let x = point.x - collectionGutter + scrollX
        guard x >= 0 else { return nil }
        let index = Int(x / metrics.pitch)
        return index < layout.albums.count ? index : nil
    }

    /// Where spine `index` is drawn, in the rack's coordinates.
    private func spineFrame(_ index: Int, layout: RackLayout, metrics: RackMetrics) -> CGRect {
        CGRect(x: collectionGutter + layout.x(of: index) - scrollX, y: metrics.top,
               width: metrics.spineWidth, height: metrics.spineHeight)
    }

    private func clampedScroll(_ x: CGFloat, layout: RackLayout) -> CGFloat {
        let maxX = max(0, layout.contentWidth + collectionGutter * 2 - available.width)
        return min(max(0, x), maxX)
    }

    // MARK: - Readout

    /// The hovered album's details under the shelf: what it is, who made it,
    /// the facts and its place in the rack. Sized to the room below the
    /// spines; dropped to one line, or left out, when the window is short.
    @ViewBuilder
    private func readout(_ metrics: RackMetrics, layout: RackLayout) -> some View {
        let top = metrics.top + metrics.spineHeight + 34
        let room = available.height - top
        let index = readoutID.flatMap { id in layout.albums.firstIndex { $0.id == id } }
            ?? playingIndex(layout)
            ?? layout.visibleRange(from: scrollX, to: scrollX + available.width).first
        if room >= 40, let index {
            let album = layout.albums[index]
            let full = room >= 104
            HStack(alignment: .lastTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    if full {
                        Text(album.year.map { "Album · \($0)" } ?? "Album")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.bottom, 6)
                    }
                    Text(album.name)
                        .font(.system(size: full ? 30 : 20, weight: .heavy))
                        .tracking(full ? -1 : -0.4)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text(layout.credits[index])
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        if full {
                            Text(facts(album))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                            qualityBadge(album)
                        }
                    }
                    .lineLimit(1)
                    .padding(.top, full ? 8 : 3)
                }
                .id(album.id)
                .transition(.opacity)
                Spacer(minLength: 0)
                Text("\(index + 1) of \(layout.albums.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: album.id)
            .frame(width: available.width - collectionGutter * 2 - 24, alignment: .leading)
            .offset(x: collectionGutter + 12, y: top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func playingIndex(_ layout: RackLayout) -> Int? {
        guard let current = player.currentTrack?.id else { return nil }
        return layout.albums.firstIndex { album in album.tracks.contains { $0.id == current } }
    }

    // MARK: - Taking a case out

    private func takeOut(_ album: Album, at spine: CGRect) {
        closeTask?.cancel()
        hoveredID = nil
        let front = caseFrame(metrics)
        takenFrom = spine
        takenOut = album
        isOut = false
        // Decode the cover at the case's size and sample its colours for the
        // disc first, so neither pops in mid-animation; then go.
        let scale = displayScale
        Task { @MainActor in
            if let data = album.artwork, !data.isEmpty {
                let id = "album:\(album.id)"
                async let caseArt = ArtworkImageCache.shared.thumbnailAsync(
                    for: data, id: id, pointSize: ArtworkImageCache.decodePointSize(for: front.width), scale: scale)
                async let palette = CoverPalette.load(for: data)
                _ = await (caseArt, palette)
            }
            guard takenOut?.id == album.id else { return }
            isOut = true
        }
    }

    private func putBack() {
        isOut = false
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            // Once the case has seated (0.2s wait + 0.85s turn) and the rack
            // is back, swap it for the shelf's own spine.
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 1120))
            guard !Task.isCancelled else { return }
            takenOut = nil
        }
    }

    /// Where the case's front cover settles: left, level with the spines.
    private func caseFrame(_ metrics: RackMetrics) -> CGRect {
        // As tall as a spine, unless the window is too narrow to fit the
        // case, the slid-out disc and the details beside them.
        let byWidth = (available.width - collectionGutter * 2 - 40 - 72 - 300) / 1.62
        let size = max(200, min(metrics.caseSize, byWidth))
        return CGRect(x: collectionGutter + 40, y: metrics.top + (metrics.spineHeight - size) / 2, width: size, height: size)
    }

    /// The sequence, each part on its own clock: the rack falls back; the
    /// case lifts from its slot and turns from its spine to its front,
    /// settling at a slight angle; the disc slides out from behind it; the
    /// details follow. Going back runs it the other way round.
    private func caseStage(_ album: Album, metrics: RackMetrics) -> some View {
        let front = caseFrame(metrics)
        let size = front.width
        let discSize = size * 0.92
        let discTravel = size * 0.6
        // The box is drawn at the case's size; on the shelf it's scaled so
        // its spine face matches a shelf spine.
        let restScale = takenFrom.height / size
        let depth = takenFrom.width / max(restScale, 0.01)
        let lift = reduceMotion ? Animation.easeOut(duration: 0.25) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.9)
        // Back in: eased at both ends, so the case glides into its slot
        // rather than rushing there and creeping the last few points.
        let seat = reduceMotion ? Animation.easeOut(duration: 0.25) : .timingCurve(0.45, 0, 0.2, 1, duration: 0.85).delay(0.2)

        return ZStack(alignment: .topLeading) {
            // The disc, behind the case, sliding out to the right.
            RackDisc(album: album, colors: RackDisc.colors(for: album), diameter: discSize, isSpinning: isOut && !reduceMotion && isPlaying(album))
                .position(
                    x: front.midX + (isOut ? discTravel : 0),
                    y: front.midY
                )
                .opacity(isOut ? 1 : 0)
                .animation(isOut
                    ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(reduceMotion ? 0 : 0.5)
                    : .timingCurve(0.4, 0, 0.6, 1, duration: 0.35), value: isOut)

            RackBox(album: album, credit: credit(album), size: size, depth: depth, angle: isOut ? RackBox.restingAngle : 90)
                .scaleEffect(isOut ? 1 : restScale)
                .position(
                    x: isOut ? front.midX : takenFrom.midX,
                    y: isOut ? front.midY : takenFrom.midY
                )
                .animation(isOut ? lift : seat, value: isOut)

            details(album)
                .frame(width: max(260, available.width - (front.maxX + discTravel + 72) - collectionGutter), alignment: .leading)
                .offset(x: front.maxX + discTravel + 72 + (isOut ? 0 : 24), y: front.minY + 30)
                .opacity(isOut ? 1 : 0)
                .animation(isOut ? .easeOut(duration: 0.45).delay(reduceMotion ? 0 : 0.75) : .easeIn(duration: 0.18), value: isOut)
                .allowsHitTesting(isOut)

            Button(action: putBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(GlassIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Back to shelf")
            .accessibilityLabel("Back to shelf")
            .offset(x: collectionGutter, y: 0)
            .opacity(isOut ? 1 : 0)
            .animation(isOut ? .easeOut(duration: 0.3).delay(reduceMotion ? 0 : 0.6) : .easeIn(duration: 0.15), value: isOut)
            .allowsHitTesting(isOut)
        }
        .frame(width: available.width, height: available.height, alignment: .topLeading)
    }

    private func credit(_ album: Album) -> String {
        album.isCompilation ? "Compilation" : (ArtistResolver.displayString(album.albumArtist ?? album.artist) ?? "Unknown Artist")
    }

    /// Tracks, running time and genre, as one line.
    private func facts(_ album: Album) -> String {
        let minutes = Int((album.tracks.compactMap(\.duration).reduce(0, +) / 60).rounded())
        var facts = ["\(album.tracks.count) track\(album.tracks.count == 1 ? "" : "s")"]
        if minutes > 0 { facts.append("\(minutes) min") }
        if let genre = album.genre { facts.append(genre) }
        return facts.joined(separator: " · ")
    }

    private func qualityBadge(_ album: Album) -> some View {
        Group {
            if let quality = album.qualitySummary {
                Text(quality.text)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(quality.color)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(quality.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func details(_ album: Album) -> some View {
        let credit = credit(album)

        return VStack(alignment: .leading, spacing: 0) {
            Text(album.year.map { "Album · \($0)" } ?? "Album")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            Text(album.name)
                .font(.system(size: 52, weight: .heavy))
                .tracking(-2)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text(credit)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.top, 12)
            HStack(spacing: 12) {
                Text(facts(album))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textTertiary)
                qualityBadge(album)
            }
            .padding(.top, 14)
            HStack(spacing: 10) {
                Button { play(album) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(FLActionPillStyle(isPrimary: true))
                Button { open(album) } label: {
                    Label("Open Album", systemImage: "arrow.up.right")
                }
                .buttonStyle(FLActionPillStyle())
            }
            .padding(.top, 26)
        }
        .flContextMenu { contextMenu(album) }
    }

    private func isPlaying(_ album: Album) -> Bool {
        guard player.isPlaying, let current = player.currentTrack?.id else { return false }
        return album.tracks.contains { $0.id == current }
    }

    private func play(_ album: Album) {
        guard !album.tracks.isEmpty else { return }
        player.isShuffleEnabled = false
        player.startFreshQueue(album.tracks, startAt: 0, source: album.name)
        player.engine.play()
        listening.recordAlbumPlay(album)
    }
}

// MARK: - Metrics

/// Sizes for the rack, from the space it has. Rounded to 8pt steps so a
/// window resize doesn't re-lay the rack (or re-render spines) every pixel.
struct RackMetrics: Hashable {
    let spineHeight: CGFloat

    init(available: CGSize) {
        let fitted = min(480, max(260, available.height - 140))
        spineHeight = (fitted / 8).rounded(.down) * 8
    }

    var spineWidth: CGFloat { (spineHeight * 0.078).rounded() }
    var gap: CGFloat { 2 }
    var pitch: CGFloat { spineWidth + gap }
    /// Room above the spines for the group tabs and the hover lift.
    var top: CGFloat { 64 }
    var hoverLift: CGFloat { 18 }
    var caseSize: CGFloat { spineHeight }
}

// MARK: - Layout

/// Where every spine and group tab sits along the rack.
struct RackLayout {
    struct Tab: Identifiable {
        let label: String
        let firstIndex: Int
        var id: Int { firstIndex }
    }

    struct Key: Hashable {
        var albums: [String] = []
        var sort: CollectionSortOption = .album
        var metrics: RackMetrics? = nil
    }

    private(set) var albums: [Album] = []
    /// Each album's display credit, worked out once rather than on every
    /// frame of a scroll.
    private(set) var credits: [String] = []
    private(set) var tabs: [Tab] = []
    private(set) var key = Key()
    private var pitch: CGFloat = 1

    init() {}

    init(albums: [Album], sort: CollectionSortOption, metrics: RackMetrics) {
        key = Key(albums: albums.map(\.id), sort: sort, metrics: metrics)
        self.albums = albums
        credits = albums.map {
            $0.isCompilation ? "Compilation" : (ArtistResolver.displayString($0.albumArtist ?? $0.artist) ?? "Unknown Artist")
        }
        pitch = metrics.pitch
        let groupOf: (Album) -> String
        switch sort {
        case .album:
            groupOf = { Self.initial($0.name) }
        case .artist:
            groupOf = { Self.initial(ArtistResolver.displayString($0.albumArtist ?? $0.artist) ?? "") }
        case .year:
            groupOf = { album in album.year.map { "'" + String(String($0).suffix(2)) } ?? "Undated" }
        case .genre:
            groupOf = { $0.genre ?? "Unknown" }
        }
        var last: String?
        for (index, album) in albums.enumerated() {
            let group = groupOf(album)
            if group != last { tabs.append(Tab(label: group, firstIndex: index)) }
            last = group
        }
    }

    /// A–Z for names starting with a letter, # for anything else.
    private static func initial(_ name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let letter = String(first).uppercased()
        return letter.rangeOfCharacter(from: .letters) != nil ? letter : "#"
    }

    var contentWidth: CGFloat { CGFloat(albums.count) * pitch }

    func x(of index: Int) -> CGFloat { CGFloat(index) * pitch }

    /// Spines overlapping `start..<end` in rack coordinates.
    func visibleRange(from start: CGFloat, to end: CGFloat) -> Range<Int> {
        guard !albums.isEmpty else { return 0..<0 }
        let lower = max(0, Int((start / pitch).rounded(.down)))
        let upper = min(albums.count, Int((end / pitch).rounded(.up)) + 1)
        return lower..<max(lower, upper)
    }
}

// MARK: - Spine

/// One CD spine: a blurred slice of the album's art under clear plastic, the
/// title and artist printed down it.
private struct RackSpine: View, Equatable {
    let album: Album
    let credit: String
    let width: CGFloat
    let height: CGFloat
    let isHovered: Bool

    @State private var art: NSImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let art {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
            }
            // A plain wash rather than colour filters or a text shadow, so a
            // moving spine costs no per-frame effects; it also keeps the
            // printed title readable on bright art.
            Color.black.opacity(isHovered ? 0.06 : 0.2)
            // The plastic: a hard highlight down the left edge, a soft sheen.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.18),
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.18), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(colors: [.white.opacity(0.1), .clear, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom)
            spineText
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white.opacity(isHovered ? 0.3 : 0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isHovered ? 0.6 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 12 : 0)
        .task(id: album.id) { await loadArt() }
    }

    private var spineText: some View {
        HStack(spacing: 6) {
            Text(album.name)
                .font(.system(size: 12.5, weight: .heavy))
            Text(credit)
                .font(.system(size: 12.5, weight: .medium))
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(width: height - 28, alignment: .leading)
        .rotationEffect(.degrees(90))
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// The art, blurred once off the main thread into a tiny bitmap and kept
    /// for the session; it's drawn scaled up, so no blur runs while the rack
    /// scrolls.
    private func loadArt() async {
        guard let data = album.artwork, !data.isEmpty else { return }
        let id = "rack-spine:\(album.id)"
        if let hit = BlurredArtworkCache.shared.cached(id: id) {
            art = hit
            return
        }
        let box = await BlurredArtworkCache.shared.image(for: data, id: id, maxPixel: 48, radius: 3)
        guard !Task.isCancelled else { return }
        art = box.image
    }

    /// By identity: `Album`'s own equality walks every track.
    nonisolated static func == (lhs: RackSpine, rhs: RackSpine) -> Bool {
        lhs.album.id == rhs.album.id
            && lhs.album.name == rhs.album.name
            && lhs.credit == rhs.credit
            && lhs.album.artwork?.count == rhs.album.artwork?.count
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.isHovered == rhs.isHovered
    }
}

/// The small tab above the first spine of a group.
private struct RackTab: View {
    static let height: CGFloat = 22

    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .heavy).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: Self.height, maxHeight: Self.height)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                    .fill(Theme.surfaceElevated)
            )
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Case and disc

/// The jewel case out of the rack, as a box: a front with the cover, the
/// spine on its left and a clear plastic edge on its right. One animated
/// `angle` turns the whole box about its centre: 90° shows the spine face on,
/// exactly as on the shelf; a small negative angle shows the front with the
/// near edge turned toward you, so the case reads as an object.
///
/// Each face is projected with its own perspective matrix (the same maths as
/// CSS's `perspective` + `rotateY` + `translateZ`), which places the faces as
/// one solid rather than as separately tilted pictures.
private struct RackBox: View, Animatable {
    static let restingAngle: Double = -14

    let album: Album
    let credit: String
    let size: CGFloat
    let depth: CGFloat
    var angle: Double

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if let spine = face(width: depth, turnedBy: -90, out: size / 2) {
                RackSpine(album: album, credit: credit, width: depth, height: size, isHovered: false)
                    .equatable()
                    .overlay(Color.black.opacity(spine.shade))
                    .projectionEffect(spine.transform)
            }
            if let edge = face(width: depth, turnedBy: 90, out: size / 2) {
                edgeFace
                    .overlay(Color.black.opacity(edge.shade))
                    .projectionEffect(edge.transform)
            }
            if let front = face(width: size, turnedBy: 0, out: depth / 2) {
                frontFace
                    .overlay(Color.black.opacity(front.shade))
                    .projectionEffect(front.transform)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A face `width` wide, turned `turnedBy`° from the front and standing
    /// `out` from the box's centre: its projection and how much it's shaded,
    /// or nil while it faces away.
    private func face(width: CGFloat, turnedBy: Double, out: CGFloat) -> (transform: ProjectionTransform, shade: Double)? {
        let total = (angle + turnedBy) * .pi / 180
        guard cos(total) > 0.001 else { return nil }
        let turn = angle * .pi / 180
        // Keep whichever face is toward you in the picture plane, so the
        // spine on the shelf and the front once out are drawn at true size.
        let shift = -(size / 2) * max(0, sin(turn)) - (depth / 2) * max(0, cos(turn))

        var rotation = CATransform3DIdentity
        rotation.m11 = cos(total); rotation.m13 = -sin(total)
        rotation.m31 = sin(total); rotation.m33 = cos(total)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (size * 3.2)

        var t = CATransform3DMakeTranslation(-width / 2, -size / 2, out)
        t = CATransform3DConcat(t, rotation)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, 0, shift))
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(width / 2, size / 2, 0))
        // Faces turned from the light darken a little.
        return (ProjectionTransform(t), (1 - cos(total)) * 0.45)
    }

    /// The case's open side: clear plastic over the tray's dark edge.
    private var edgeFace: some View {
        ZStack {
            Color(white: 0.09)
            LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: depth, height: size)
        .overlay(Rectangle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var frontFace: some View {
        ZStack(alignment: .leading) {
            ArtworkView(data: album.artwork, size: size, id: "album:\(album.id)", showsShadow: false, alwaysSquare: true)
            // The hinge strip down the left, and the plastic over the cover.
            LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05), .black.opacity(0.25)], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(10, size * 0.045))
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.2), location: 0),
                    .init(color: .clear, location: 0.32),
                    .init(color: .clear, location: 0.7),
                    .init(color: .white.opacity(0.07), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 22, y: 20)
    }
}

/// The CD: silver with a rainbow sheen, printed with a soft, bubbly field of
/// three colours taken from the album's cover around a clear hub. The print
/// turns slowly while its album plays.
private struct RackDisc: View {
    let album: Album
    /// Passed in rather than read here, so the disc redraws once they're
    /// sampled.
    let colors: [Color]
    let diameter: CGFloat
    let isSpinning: Bool

    @State private var angle: Double = 0

    var body: some View {
        let print = (diameter * 0.64).rounded()
        ZStack {
            Circle()
                .fill(AngularGradient(
                    colors: [
                        Color(white: 0.85), Color(white: 0.96), Color(red: 0.75, green: 0.9, blue: 1),
                        Color(red: 0.91, green: 0.82, blue: 1), Color(red: 1, green: 0.9, blue: 0.77),
                        Color(white: 0.85), Color(white: 0.96), Color(red: 0.79, green: 0.95, blue: 0.9),
                        Color(white: 0.88), Color(white: 0.85),
                    ],
                    center: .center,
                    angle: .degrees(30)
                ))
            // The print, as a ring around the hub.
            RackDiscPrint(colors: colors, seed: seed, size: print)
                .mask {
                    Circle().strokeBorder(lineWidth: (print - diameter * 0.2) / 2)
                }
                .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5).frame(width: print, height: print))
                .rotationEffect(.degrees(angle))
            // The hub: a clear ring and the centre hole.
            Circle()
                .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                .frame(width: diameter * 0.165, height: diameter * 0.165)
            Circle()
                .fill(Theme.background)
                .frame(width: diameter * 0.075, height: diameter * 0.075)
            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isSpinning, initial: true) { _, spinning in
            if spinning {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { angle = 360 }
            } else {
                withAnimation(.easeOut(duration: 0.4)) { angle = 0 }
            }
        }
    }

    /// Three colours from the cover (sampled before the disc comes out);
    /// soft greys when there's no cover to sample.
    static func colors(for album: Album) -> [Color] {
        if case let palette?? = CoverPalette.cached(for: album.artwork) { return palette.series(3) }
        return [Color(white: 0.42), Color(white: 0.62), Color(white: 0.3)]
    }

    /// Stable per album, so each disc's print is laid out its own way but
    /// the same way every time.
    private var seed: Int {
        album.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

/// The disc's print: overlapping soft blobs of three colours on a deep base,
/// under a faint sheen. Gradients only, so it costs nothing to draw or spin.
private struct RackDiscPrint: View {
    let colors: [Color]
    let seed: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            colors[2]
            Color.black.opacity(0.18)
            ForEach(0..<5, id: \.self) { i in
                let place = blob(i)
                RadialGradient(
                    colors: [colors[i % 3], colors[i % 3].opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: place.radius
                )
                .frame(width: place.radius * 2, height: place.radius * 2)
                .offset(x: place.x, y: place.y)
            }
            // A light catch across the print, as on a glossy pressing.
            AngularGradient(
                colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                center: .center,
                angle: .degrees(Double(seed % 360))
            )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Where blob `i` sits and how big it is: spread around the ring at
    /// seeded angles and distances.
    private func blob(_ i: Int) -> (x: CGFloat, y: CGFloat, radius: CGFloat) {
        let mix = (seed &* (i + 7) &* 2654435761) & 0xFFFF
        let turn = Double(i) / 5 * 2 * .pi + Double(mix % 100) / 100 * 1.2
        let distance = size * (0.18 + CGFloat(mix % 37) / 37 * 0.16)
        let radius = size * (0.26 + CGFloat((mix / 37) % 29) / 29 * 0.16)
        return (distance * CGFloat(cos(turn)), distance * CGFloat(sin(turn)), radius)
    }
}

// MARK: - Scrolling

/// Turns scrolling over the rack into horizontal travel: trackpad deltas in
/// points, mouse-wheel notches in fixed steps, either axis. Scrolling down or
/// right moves forward. The rack takes the scroll, so the page stays put.
private struct RackScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?
        /// Points moved per mouse-wheel notch.
        private let notch: CGFloat = 72

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                // The dominant axis; negative content deltas (down / right) go forward.
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                    ? event.scrollingDeltaY : event.scrollingDeltaX
                guard delta != 0 else { return nil }
                let travel = event.hasPreciseScrollingDeltas ? -delta : (delta < 0 ? self.notch : -self.notch)
                self.onScroll?(travel)
                return nil
            }
        }
    }
}
