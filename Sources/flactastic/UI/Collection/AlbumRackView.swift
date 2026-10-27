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
    @Environment(Settings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// How far the rack is scrolled, in points.
    @State private var scrollX: CGFloat = 0
    @State private var hoveredID: String?
    /// Where the clear-case sheen sits down the hovered spine, from its top.
    /// Springs after the pointer, so it rushes to catch up and settles softly.
    @State private var sheenY: CGFloat = 0
    /// The album the readout under the shelf shows: the last one hovered, so
    /// it doesn't blink out as the pointer crosses a gap.
    @State private var readoutID: String?
    @State private var cachedLayout = RackLayout()

    // The case taken out of the rack.
    @State private var takenOut: Album?
    /// Where its spine sat, in the rack's coordinates, so it can go back.
    @State private var takenFrom: CGRect = .zero
    @State private var stage: CaseStage = .shelf
    /// Which way the case is travelling, so each stage picks its curve.
    @State private var isClosing = false
    /// The rest of the rack falls back while a case is out.
    @State private var shelfReceded = false
    @State private var sequence: Task<Void, Never>?

    private var isOut: Bool { stage == .open }

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
                .blur(radius: shelfReceded && !reduceMotion ? 10 : 0)
                .opacity(shelfReceded ? 0.16 : 1)
                .scaleEffect(shelfReceded ? 0.96 : 1, anchor: .center)
                // Falls back as the case comes out; comes forward again as
                // the case reaches its slot, so it slides into a sharp shelf.
                .animation(shelfReceded ? .easeOut(duration: 0.5) : .easeOut(duration: 0.45).delay(0.6), value: shelfReceded)
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
                        isHovered: hovered,
                        clearCase: settings.clearCaseLook
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
                // The sheen on the hovered spine only, drawn apart from the
                // spines so following the pointer redraws nothing else.
                if settings.clearCaseLook, takenOut == nil, let id = hoveredID,
                   let index = layout.albums.firstIndex(where: { $0.id == id }), visible.contains(index) {
                    RackSheen(width: metrics.spineWidth, height: metrics.spineHeight, y: sheenY)
                        .offset(x: layout.x(of: index), y: metrics.top - metrics.hoverLift)
                        .zIndex(2)
                        .id(id)
                        .transition(.opacity)
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
        // Watched at the window level rather than with `onContinuousHover`,
        // whose tracking went stale after returning from an album page (the
        // rack is rebuilt mid-transition), leaving spines that never lift.
        .background {
            PointerWatcher(
                onMove: { point in
                    let inside = point.x >= 0 && point.x <= available.width
                    hover(inside ? spineIndex(at: point, layout: layout, metrics: metrics).map { layout.albums[$0].id } : nil)
                    if settings.clearCaseLook, hoveredID != nil {
                        let y = point.y - (metrics.top - metrics.hoverLift)
                        if reduceMotion {
                            sheenY = y
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 1)) { sheenY = y }
                        }
                    }
                },
                onExit: { hover(nil) }
            )
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

    private func hover(_ id: String?) {
        // The watcher sees moves even while a case is out and the shelf
        // ignores the pointer; nothing on the shelf lifts then.
        let id = takenOut == nil ? id : nil
        if id != hoveredID { hoveredID = id }
        if let id, id != readoutID { readoutID = id }
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
        sequence?.cancel()
        hoveredID = nil
        let front = caseFrame(metrics)
        takenFrom = spine
        takenOut = album
        stage = .shelf
        isClosing = false
        // Decode the cover at the case's size and sample its colours for the
        // disc first, so neither pops in mid-animation; then go.
        let scale = displayScale
        let reduceMotion = reduceMotion
        sequence = Task { @MainActor in
            if let data = album.artwork, !data.isEmpty {
                let id = "album:\(album.id)"
                async let caseArt = ArtworkImageCache.shared.thumbnailAsync(
                    for: data, id: id, pointSize: ArtworkImageCache.decodePointSize(for: front.width), scale: scale)
                async let palette = CoverPalette.load(for: data)
                _ = await (caseArt, palette)
            }
            guard !Task.isCancelled, takenOut?.id == album.id else { return }
            shelfReceded = true
            if !reduceMotion {
                // Out of the slot towards the viewer, still edge-on…
                stage = .pulled
                try? await Task.sleep(for: .milliseconds(Int(CaseStage.pullDuration * 1000)))
                guard !Task.isCancelled else { return }
            }
            // …then it turns to its front and opens.
            stage = .open
        }
    }

    private func putBack() {
        sequence?.cancel()
        isClosing = true
        shelfReceded = false
        let reduceMotion = reduceMotion
        sequence = Task { @MainActor in
            if !reduceMotion {
                // The disc goes in and the case turns back to its spine,
                // hovering just out of its slot (0.2s wait + 0.85s turn)…
                stage = .pulled
                try? await Task.sleep(for: .milliseconds(1050))
                guard !Task.isCancelled else { return }
            }
            // …then slides home.
            stage = .shelf
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : Int(CaseStage.pullDuration * 1000) + 60))
            guard !Task.isCancelled else { return }
            // Swap it for the shelf's own spine.
            takenOut = nil
            isClosing = false
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
        // Pulled clear of the shelf, the case is nearer the viewer than its
        // neighbours, so a little larger.
        let pulledScale = restScale * CaseStage.pullScale
        let caseScale: CGFloat
        let caseCentre: CGPoint
        let caseMotion: Animation
        switch stage {
        case .shelf:
            caseScale = restScale
            caseCentre = CGPoint(x: takenFrom.midX, y: takenFrom.midY)
            // Back into the slot: eased at both ends, so it glides home.
            caseMotion = reduceMotion ? .easeOut(duration: 0.25) : .timingCurve(0.45, 0, 0.25, 1, duration: CaseStage.pullDuration)
        case .pulled:
            caseScale = pulledScale
            caseCentre = CGPoint(x: takenFrom.midX, y: takenFrom.midY)
            caseMotion = isClosing
                // Turning back to its spine, after the disc has gone in.
                ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.85).delay(0.2)
                : .timingCurve(0.25, 0.8, 0.35, 1, duration: CaseStage.pullDuration)
        case .open:
            caseScale = 1
            caseCentre = CGPoint(x: front.midX, y: front.midY)
            caseMotion = reduceMotion ? .easeOut(duration: 0.25) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.9)
        }

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

            RackBox(album: album, credit: credit(album), size: size, depth: depth, shelfScale: restScale, clearCase: settings.clearCaseLook, angle: isOut ? RackBox.restingAngle : 90)
                .scaleEffect(caseScale)
                .shadow(color: .black.opacity(stage == .shelf ? 0 : 0.4), radius: 14, y: 8)
                .position(caseCentre)
                .animation(caseMotion, value: stage)

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

/// One CD spine: a blurred slice of the album's art with the title and
/// artist printed down it. In the clear-case look the printed card sits just
/// inside a plastic lid: a bright rim, lighter caps at top and bottom and a
/// hard highlight down the hinge side.
private struct RackSpine: View, Equatable {
    let album: Album
    let credit: String
    let width: CGFloat
    let height: CGFloat
    let isHovered: Bool
    var clearCase: Bool = false
    /// One shelf point in this spine's own points: above 1 when it's drawn
    /// large and scaled down (the case's spine face), so its rim, insets and
    /// print come out the same as on the shelf.
    var unit: CGFloat = 1

    @State private var art: NSImage?

    var body: some View {
        Group {
            if clearCase {
                ZStack {
                    Color(white: 0.07)
                    printed
                        .clipShape(RoundedRectangle(cornerRadius: unit))
                        .padding(.vertical, 3 * unit)
                        .padding(.horizontal, 1.5 * unit)
                    lid
                }
            } else {
                ZStack {
                    printed
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
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2 * unit))
        .overlay(
            RoundedRectangle(cornerRadius: 2 * unit)
                .strokeBorder(.white.opacity(isHovered ? 0.3 : clearCase ? 0.2 : 0.14), lineWidth: (clearCase ? 1 : 0.5) * unit)
        )
        .shadow(color: .black.opacity(isHovered ? 0.6 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 12 : 0)
        .task(id: album.id) { await loadArt() }
    }

    /// The printed spine card.
    private var printed: some View {
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
            spineText
        }
    }

    /// The clear lid over the card: caps, and the hinge-side highlights.
    private var lid: some View {
        let cap = 3 * unit / max(height, 1), soft = 6 * unit / max(height, 1)
        let px = unit / max(width, 1)
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0.04), location: cap),
                    .init(color: .clear, location: soft),
                    .init(color: .clear, location: 1 - soft),
                    .init(color: .white.opacity(0.04), location: 1 - cap),
                    .init(color: .white.opacity(0.18), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.55), location: 2 * px),
                    .init(color: .white.opacity(0.08), location: 4 * px),
                    .init(color: .clear, location: 9 * px),
                    .init(color: .clear, location: 1 - 9 * px),
                    .init(color: .white.opacity(0.05), location: 1 - 4 * px),
                    .init(color: .white.opacity(0.28), location: 1 - 2 * px),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
    }

    private var spineText: some View {
        HStack(spacing: 6 * unit) {
            Text(album.name)
                .font(.system(size: 12.5 * unit, weight: .heavy))
            Text(credit)
                .font(.system(size: 12.5 * unit, weight: .medium))
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(width: height - 28 * unit, alignment: .leading)
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
            && lhs.clearCase == rhs.clearCase
            && lhs.unit == rhs.unit
    }
}

/// The clear-case sheen: a slightly tilted band of light across a spine,
/// centred `y` from its top.
private struct RackSheen: View {
    static let band: CGFloat = 150

    let width: CGFloat
    let height: CGFloat
    let y: CGFloat

    var body: some View {
        RackSheenBand(tilt: -8)
            .frame(width: width * 3, height: Self.band)
            .position(x: width / 2, y: y)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A soft band of light, brightest just above its middle.
private struct RackSheenBand: View {
    let tilt: Double
    var strength: Double = 1
    /// Vertical runs the band across, top to bottom; horizontal, side to side.
    var axis: Axis = .vertical

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.1 * strength), location: 0.3),
                .init(color: .white.opacity(0.6 * strength), location: 0.47),
                .init(color: .white.opacity(0.14 * strength), location: 0.54),
                .init(color: .clear, location: 0.72),
            ],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
        .rotationEffect(.degrees(tilt))
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

/// Where a taken-out case is: in its slot, pulled clear of it edge-on, or
/// turned to its front with the disc out.
enum CaseStage {
    case shelf, pulled, open

    static let pullDuration: Double = 0.4
    static let pullScale: CGFloat = 1.14
}

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
    /// The scale the box is shrunk to on the shelf, so its spine face's
    /// plastic matches the shelf spine it's swapped for, point for point.
    var shelfScale: CGFloat = 1
    var clearCase: Bool = false
    var angle: Double

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if let spine = face(width: depth, turnedBy: -90, out: size / 2) {
                RackSpine(album: album, credit: credit, width: depth, height: size, isHovered: false, clearCase: clearCase, unit: 1 / max(shelfScale, 0.01))
                    .equatable()
                    .overlay { if clearCase { turnSheen(width: depth, reversed: true) } }
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

    /// How far through its turn the case is: 0 edge-on, 1 at rest front-on.
    private var turnProgress: CGFloat {
        CGFloat(min(1, max(0, (90 - angle) / (90 - Self.restingAngle))))
    }

    /// A band of light that sweeps across a face as the case turns. It fades
    /// to nothing at either end of the turn, so nothing is left on the case
    /// when it settles, or when it's swapped for the shelf's own spine.
    private func turnSheen(width: CGFloat, reversed: Bool = false) -> some View {
        let t = reversed ? 1 - turnProgress : turnProgress
        return RackSheenBand(tilt: reversed ? 0 : 15, strength: 0.75 * sin(.pi * Double(t)), axis: .horizontal)
            .frame(width: width * 3, height: size * 1.4)
            .position(x: width * 1.5 - width * 2 * (1 - t), y: size / 2)
            .frame(width: width, height: size)
            .clipped()
            .blendMode(.plusLighter)
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
        Group {
            if clearCase {
                clearFront
            } else {
                ZStack(alignment: .leading) {
                    ArtworkView(data: album.artwork, size: size, id: "album:\(album.id)", showsShadow: false, alwaysSquare: true)
                    // The hinge strip down the left, and the plastic over the cover.
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05), .black.opacity(0.25)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(10, size * 0.045))
                    lidGloss
                }
                .frame(width: size, height: size)
                .clipped()
                .overlay(Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 22, y: 20)
    }

    /// The cover under a clear lid: the booklet set just inside the plastic,
    /// a ridged hinge strip down the left, a bright rim and a sheen that
    /// sweeps across as the case turns.
    private var clearFront: some View {
        let inset = max(3, size * 0.017)
        let hinge = max(12, size * 0.067)
        return ZStack(alignment: .topLeading) {
            Color(white: 0.07)
            ArtworkView(data: album.artwork, size: size - hinge - inset, id: "album:\(album.id)", showsShadow: false, alwaysSquare: true)
                .frame(width: size - hinge - inset, height: size - inset * 2)
                .clipped()
                .offset(x: hinge, y: inset)
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
            lidGloss
            turnSheen(width: size)
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
    }

    private var lidGloss: some View {
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
