import SwiftUI
import AppKit

/// The Collection tab's album shelf: a deck of covers fanned out from the
/// selected album. Albums before it stack to the left showing their left
/// edges, albums after it stack to the right showing their right edges, and
/// the selected album sits on top with its record slid out to the right.
/// Scrolling (wheel or trackpad) steps through the deck, as do the arrow
/// keys; clicking the selected album opens it, clicking another brings it
/// forward. Its details sit below the shelf. Year and Genre sorts drop a
/// divider wherever the group changes.
///
/// Covers size themselves to the space the page gives the shelf, so the
/// deck fills the window instead of leaving it empty.
///
/// Built for fast stepping: cards sit at fixed positions inside one
/// container and the container slides, so a step animates a single
/// transform rather than every card. Only cards near the window are drawn,
/// only the selected card carries a record, shadows are pre-rendered images
/// rather than live blurs, and the deck is never masked or composited
/// offscreen.
struct AlbumShelfView: View {
    /// Already sorted and filtered by the Collection page.
    let albums: [Album]
    let sort: CollectionSortOption
    /// The space the page has for the shelf and its details.
    let available: CGSize
    let open: (Album) -> Void
    let contextMenu: (Album) -> [FLContextMenuItem]

    @Environment(PlayerState.self)     private var player
    @Environment(ListeningStore.self)  private var listening
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedAlbumID: String?
    /// The deck takes focus when it appears and when clicked, so the arrow
    /// keys and Return reach it instead of beeping.
    @FocusState private var isFocused: Bool
    /// The layout only depends on the albums, the sort and the cover size,
    /// so it's kept between steps and rebuilt only when one of those changes.
    @State private var cachedLayout = ShelfLayout()

    private static let motion = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32)

    private var metrics: ShelfMetrics { ShelfMetrics(available: available) }

    private var layoutKey: ShelfLayout.Key {
        ShelfLayout.Key(albums: albums.map(\.id), sort: sort, metrics: metrics)
    }

    /// The cached layout, or a fresh one for this frame when it's stale, so
    /// the first frame after a change is never empty.
    private var layout: ShelfLayout {
        cachedLayout.key == layoutKey ? cachedLayout : ShelfLayout(albums: albums, sort: sort, metrics: metrics)
    }

    private func selectedIndex(in layout: ShelfLayout) -> Int {
        layout.index(of: selectedAlbumID) ?? 0
    }

    var body: some View {
        let metrics = metrics
        let layout = layout
        let selectedIndex = selectedIndex(in: layout)
        VStack(alignment: .leading, spacing: ShelfMetrics.detailsSpacing) {
            if !layout.cards.isEmpty {
                deck(metrics, layout: layout, selected: selectedIndex)
                let album = layout.cards[selectedIndex].album
                ShelfAlbumInfo(
                    album: album,
                    position: "\(selectedIndex + 1) of \(layout.cards.count)",
                    play: { play(album, shuffle: $0) }
                )
                .equatable()
                .padding(.horizontal, collectionGutter)
            }
        }
        .onChange(of: layoutKey, initial: true) {
            cachedLayout = ShelfLayout(albums: albums, sort: sort, metrics: metrics)
        }
    }

    // MARK: - Deck

    private func deck(_ metrics: ShelfMetrics, layout: ShelfLayout, selected: Int) -> some View {
        let selectedX = layout.cards[selected].x
        // The selection sits a fixed distance in from the left, leaving room
        // for the stack of albums before it.
        let anchor = collectionGutter + min(selectedX, metrics.leadingStack)
        let shift = anchor - selectedX
        let visible = layout.visibleRange(from: -shift - metrics.cover, to: -shift + available.width, cover: metrics.cover)

        return ZStack(alignment: .topLeading) {
            // Everything inside moves together with one offset.
            ZStack(alignment: .topLeading) {
                // Divider cards stand behind the whole deck; only their tabs
                // above the covers, and the gaps between groups, show.
                ForEach(layout.dividers.filter { visible.contains($0.firstCard) }) { divider in
                    DividerCard(label: divider.label, height: metrics.cover + DividerCard.tabHeight)
                        .offset(
                            x: layout.groupStartX(divider.firstCard, selected: selected, metrics: metrics),
                            y: metrics.topInset - DividerCard.tabHeight
                        )
                        .zIndex(-1_000_000)
                }

                ForEach(visible, id: \.self) { index in
                    let card = layout.cards[index]
                    let isSelected = index == selected
                    ShelfCover(
                        album: card.album,
                        metrics: metrics,
                        side: isSelected ? .selected : (index < selected ? .before : .after),
                        isSpinning: isSelected && !reduceMotion && isPlaying(card.album)
                    )
                    .equatable()
                    .offset(x: card.x, y: metrics.topInset - (isSelected ? metrics.lift : 0))
                    // Fanned from the selection: the nearer a card, the higher.
                    .zIndex(isSelected ? 1 : -Double(abs(index - selected)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(card.album.name), \(ArtistResolver.displayString(card.album.artist) ?? "Unknown Artist")")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { select(index, in: layout, thenOpen: isSelected) }
                }
            }
            .offset(x: shift)

            edgeFades
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: metrics.topInset + metrics.cover + 2, alignment: .topLeading)
        .animation(reduceMotion ? nil : Self.motion, value: selected)
        // Clipped at the sides, where the deck runs off; above and below,
        // the lifted cover's shadow is left room to fall softly.
        .clipShape(VerticalBleed(top: 16, bottom: 36))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { point in
            isFocused = true
            guard let index = layout.topCard(at: point.x - shift, selected: selected, metrics: metrics) else { return }
            select(index, in: layout, thenOpen: index == selected)
        }
        .flContextMenu {
            contextMenu(layout.cards[selected].album)
        }
        .background {
            ScrollWheelStepper { step(by: $0, in: layout, from: selected) }
        }
        // `.edit` makes it focusable by click and programmatically even
        // with system keyboard navigation off.
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            // Don't pull focus out of the search field mid-typing (the shelf
            // reappears when a search that matched nothing starts matching).
            if !(NSApp.keyWindow?.firstResponder is NSText) { isFocused = true }
        }
        .onKeyPress(.rightArrow) { step(by: 1, in: layout, from: selected); return .handled }
        .onKeyPress(.leftArrow) { step(by: -1, in: layout, from: selected); return .handled }
        .onKeyPress(.return) { open(layout.cards[selected].album); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Album shelf")
    }

    /// Soft ends in the page colour, painted over the deck instead of a mask
    /// so nothing has to be composited offscreen.
    private var edgeFades: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [Theme.background, Theme.background.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
            Spacer(minLength: 0)
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .leading, endPoint: .trailing)
                .frame(width: 40)
        }
        .allowsHitTesting(false)
    }

    /// Steps from the current selection. The stepper reads the selection
    /// fresh each time, since several steps can land before a redraw.
    private func step(by delta: Int, in layout: ShelfLayout, from _: Int) {
        guard !layout.cards.isEmpty else { return }
        let current = selectedIndex(in: layout)
        let target = max(0, min(layout.cards.count - 1, current + delta))
        guard target != current else { return }
        selectedAlbumID = layout.cards[target].album.id
    }

    private func select(_ index: Int, in layout: ShelfLayout, thenOpen: Bool) {
        let album = layout.cards[index].album
        if thenOpen {
            open(album)
        } else {
            selectedAlbumID = album.id
        }
    }

    private func isPlaying(_ album: Album) -> Bool {
        guard player.isPlaying, let current = player.currentTrack?.id else { return false }
        return album.tracks.contains { $0.id == current }
    }

    private func play(_ album: Album, shuffle: Bool) {
        guard !album.tracks.isEmpty else { return }
        player.isShuffleEnabled = shuffle
        let start = shuffle ? Int.random(in: 0..<album.tracks.count) : 0
        player.startFreshQueue(album.tracks, startAt: start, source: album.name)
        player.engine.play()
        listening.recordAlbumPlay(album)
    }
}

// MARK: - Metrics

/// Sizes for the deck, derived from the space it has.
///
/// The cover is the largest that fits two limits: the height left after the
/// shelf's headroom and the details row, and a width that still leaves room
/// for the stack of earlier albums, the slid-out record and a visible run of
/// later albums. It's rounded to 16pt steps so resizing the window doesn't
/// re-lay the deck (or re-decode artwork) on every pixel.
struct ShelfMetrics: Hashable {
    let cover: CGFloat

    static let detailsHeight: CGFloat = 104
    static let detailsSpacing: CGFloat = 24
    static let minCover: CGFloat = 240
    static let maxCover: CGFloat = 480
    /// How far the selected record slides out, as a fraction of the cover.
    static let recordTravel: CGFloat = 0.46

    init(available: CGSize) {
        let headroom: CGFloat = 46
        let byHeight = available.height - headroom - 2 - Self.detailsSpacing - Self.detailsHeight
        // Earlier stack + cover + record + at least ~14 later edges.
        let byWidth = (available.width - collectionGutter * 2 - 200 - 260) / (1 + Self.recordTravel)
        let fitted = min(byHeight, byWidth, Self.maxCover)
        cover = max(Self.minCover, (fitted / 16).rounded(.down) * 16)
    }

    /// How much of each cover shows beside the one on top of it.
    var step: CGFloat { max(16, (cover * 0.056).rounded()) }
    var dividerGap: CGFloat { 15 }
    var lift: CGFloat { (cover * 0.044).rounded() }
    /// Headroom above the covers for the lift and the divider tabs.
    var topInset: CGFloat { 46 }
    /// The most room the stack of earlier albums takes on the left.
    var leadingStack: CGFloat { 200 }
    var recordOffset: CGFloat { cover * Self.recordTravel }
}

// MARK: - Scroll wheel

/// Turns scrolling over the shelf into steps through the deck: one per
/// mouse-wheel notch, one per short distance on a trackpad, either axis.
/// Scrolling down or right moves forward. The shelf takes the scroll, so the
/// page doesn't move while the pointer is over it.
private struct ScrollWheelStepper: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> StepperView {
        let view = StepperView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ view: StepperView, context: Context) {
        view.onStep = onStep
    }

    final class StepperView: NSView {
        var onStep: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        /// Trackpad travel per album.
        private let distancePerStep: CGFloat = 36

        // Never takes clicks; it only listens for scrolling over its bounds.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // Installed while in a window and removed on leaving it, which
        // AppKit does before the view goes away.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.handle(event)
                return nil
            }
        }

        private func handle(_ event: NSEvent) {
            // The dominant axis; content-direction deltas, so negative means
            // "scroll down" or "scroll right": forward.
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0 else { return }

            if !event.hasPreciseScrollingDeltas {
                onStep?(delta < 0 ? 1 : -1)
                return
            }
            if event.phase == .began { accumulated = 0 }
            accumulated += delta
            while abs(accumulated) >= distancePerStep {
                let forward = accumulated < 0
                onStep?(forward ? 1 : -1)
                accumulated += forward ? distancePerStep : -distancePerStep
            }
        }
    }
}

// MARK: - Layout

/// Where every card and divider sits along the shelf.
struct ShelfLayout {
    struct Card {
        let album: Album
        let x: CGFloat
    }

    struct Divider: Identifiable {
        let label: String
        /// The group's first card.
        let firstCard: Int
        var id: Int { firstCard }
    }

    struct Key: Hashable {
        var albums: [String] = []
        var sort: CollectionSortOption = .album
        var metrics: ShelfMetrics? = nil
    }

    private(set) var cards: [Card] = []
    private(set) var dividers: [Divider] = []
    private var indexByID: [String: Int] = [:]
    private(set) var key = Key()

    init() {}

    init(albums: [Album], sort: CollectionSortOption, metrics: ShelfMetrics) {
        key = Key(albums: albums.map(\.id), sort: sort, metrics: metrics)
        let groupOf: ((Album) -> String)?
        switch sort {
        case .year:
            groupOf = { album in album.year.map { "'" + String(String($0).suffix(2)) } ?? "Undated" }
        case .genre:
            groupOf = { $0.genre ?? "Unknown" }
        case .album, .artist:
            groupOf = nil
        }

        var x: CGFloat = 0
        var lastGroup: String?
        cards.reserveCapacity(albums.count)
        for album in albums {
            if let groupOf {
                let group = groupOf(album)
                if group != lastGroup {
                    // A little room between groups, where the divider shows.
                    if lastGroup != nil { x += metrics.dividerGap }
                    dividers.append(Divider(label: group, firstCard: cards.count))
                }
                lastGroup = group
            }
            indexByID[album.id] = cards.count
            cards.append(Card(album: album, x: x))
            x += metrics.step
        }
    }

    /// Where a group's visible part begins, so its divider sits at its very
    /// left. Cards after the selection show their right edges, so the group
    /// begins at its first card's edge strip; cards before (and the
    /// selection) show their left edges, so it begins at the first card.
    /// The divider stands just left of that, in the gap between groups.
    func groupStartX(_ firstCard: Int, selected: Int, metrics: ShelfMetrics) -> CGFloat {
        let x = cards[firstCard].x
        let start = firstCard > selected ? x + metrics.cover - metrics.step : x
        return start - (firstCard == 0 ? 0 : metrics.dividerGap)
    }

    func index(of albumID: String?) -> Int? {
        albumID.flatMap { indexByID[$0] }
    }

    /// Cards whose covers overlap `start..<end` in shelf coordinates.
    func visibleRange(from start: CGFloat, to end: CGFloat, cover: CGFloat) -> Range<Int> {
        guard !cards.isEmpty else { return 0..<0 }
        let lower = firstIndex { $0.x + cover > start }
        let upper = firstIndex { $0.x > end }
        return lower..<max(lower, upper)
    }

    /// The card on top at `x`, given the fan around `selected`: the selected
    /// cover and its record first, then the nearest card covering `x` on
    /// whichever side it falls.
    func topCard(at x: CGFloat, selected: Int, metrics: ShelfMetrics) -> Int? {
        let size = metrics.cover
        let anchor = cards[selected].x
        if x >= anchor, x < anchor + size + metrics.recordOffset { return selected }
        if x < anchor {
            // Earlier cards: the latest one starting at or before x.
            let index = firstIndex { $0.x > x } - 1
            return index >= 0 && index < selected ? index : nil
        }
        // Later cards: the earliest whose cover reaches x.
        let index = firstIndex { $0.x + size > x }
        return index > selected && index < cards.count && cards[index].x <= x ? index : nil
    }

    /// Binary search: the first card matching an increasing predicate.
    private func firstIndex(where predicate: (Card) -> Bool) -> Int {
        var low = 0, high = cards.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(cards[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

// MARK: - Cover

/// One album on the shelf. Only the selected cover carries its record.
///
/// Shadows are pre-rendered images drawn at their exact size, cut to the
/// cover's own corners, so they cost no blurring while the deck moves and
/// rounded art never shows square edges. The selected cover gets a full,
/// deep shadow; the others only cast a thin one from the edge that lies
/// over their neighbour, which is the only part of it that can show.
private struct ShelfCover: View, Equatable {
    enum Side { case before, selected, after }

    let album: Album
    let metrics: ShelfMetrics
    let side: Side
    let isSpinning: Bool

    @Environment(Settings.self) private var settings

    var body: some View {
        let size = metrics.cover
        let corner = settings.roundedArtwork ? Theme.Radius.lg : 0
        ZStack(alignment: .topLeading) {
            if side == .selected {
                let diameter = (size * 0.92).rounded()
                ZStack(alignment: .topLeading) {
                    if settings.showArtworkShadow {
                        let style = ShelfShadow.record
                        Image(nsImage: ShelfShadow.image(.full, style: style, cover: diameter, corner: diameter / 2))
                            .offset(x: -style.padding, y: -style.padding + style.yOffset)
                    }
                    VinylRecord(
                        artwork: album.artwork,
                        albumID: album.id,
                        diameter: diameter,
                        isSpinning: isSpinning,
                        castsShadow: false
                    )
                }
                .frame(width: diameter, height: diameter, alignment: .topLeading)
                .padding(size * 0.04)
                .offset(x: metrics.recordOffset)
                .transition(.offset(x: -metrics.recordOffset).combined(with: .opacity))
            }

            if settings.showArtworkShadow {
                shadow(size: size, corner: corner)
            }

            ArtworkView(data: album.artwork, size: size, id: "album:\(album.id)", showsShadow: false)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Compared by identity. `Album`'s own equality walks its artwork and
    /// every track (each with artwork of its own), and SwiftUI would run it
    /// for every visible cover on every step.
    nonisolated static func == (lhs: ShelfCover, rhs: ShelfCover) -> Bool {
        lhs.album.id == rhs.album.id
            && lhs.album.artwork?.count == rhs.album.artwork?.count
            && lhs.metrics == rhs.metrics
            && lhs.side == rhs.side
            && lhs.isSpinning == rhs.isSpinning
    }

    @ViewBuilder
    private func shadow(size: CGFloat, corner: CGFloat) -> some View {
        switch side {
        case .selected:
            let style = ShelfShadow.lifted
            Image(nsImage: ShelfShadow.image(.full, style: style, cover: size, corner: corner))
                .offset(x: -style.padding, y: -style.padding + style.yOffset)
        case .before:
            // Lies over the card before it with its left edge.
            let style = ShelfShadow.stacked
            Image(nsImage: ShelfShadow.image(.leadingEdge, style: style, cover: size, corner: corner))
                .offset(x: -style.padding, y: -style.padding)
        case .after:
            // Lies over the card after it with its right edge.
            let style = ShelfShadow.stacked
            Image(nsImage: ShelfShadow.image(.trailingEdge, style: style, cover: size, corner: corner))
                .offset(x: size - corner, y: -style.padding)
        }
    }
}

/// Pre-rendered shelf shadows, one image per part, style, cover size and
/// corner radius. Cover sizes come in 16pt steps, so only a few exist.
@MainActor
enum ShelfShadow {
    struct Style: Hashable {
        let blur: CGFloat
        let opacity: CGFloat
        let yOffset: CGFloat
        /// Room around the cover for the blur to fade out.
        var padding: CGFloat { (blur * 1.5).rounded(.up) }
    }

    enum Part: Hashable {
        /// The whole shadow around the cover.
        case full
        /// Only the strip outside the left edge (and its corners).
        case leadingEdge
        /// Only the strip outside the right edge (and its corners).
        case trailingEdge
    }

    /// A tight contact shadow: one card lying on another.
    static let stacked = Style(blur: 7, opacity: 0.6, yOffset: 0)
    /// The selected cover, lifted well off the deck.
    static let lifted = Style(blur: 30, opacity: 0.7, yOffset: 18)
    /// The record sliding out from under the selected cover.
    static let record = Style(blur: 14, opacity: 0.5, yOffset: 6)

    private struct Key: Hashable {
        let part: Part
        let style: Style
        let cover: CGFloat
        let corner: CGFloat
    }
    private static var images: [Key: NSImage] = [:]

    static func image(_ part: Part, style: Style, cover: CGFloat, corner: CGFloat) -> NSImage {
        let key = Key(part: part, style: style, cover: cover, corner: corner)
        if let cached = images[key] { return cached }

        let pad = style.padding
        let height = cover + pad * 2
        // The image's size, and where the cover sits inside it.
        let width: CGFloat
        let coverX: CGFloat
        switch part {
        case .full:
            width = cover + pad * 2
            coverX = pad
        case .leadingEdge:
            width = pad + corner
            coverX = pad
        case .trailingEdge:
            width = corner + pad
            coverX = corner - cover
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = CGPath(
                roundedRect: CGRect(x: coverX, y: pad, width: cover, height: cover),
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            )
            context.setShadow(
                offset: .zero,
                blur: style.blur,
                color: NSColor.black.withAlphaComponent(style.opacity).cgColor
            )
            context.addPath(shape)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            // Keep only the shadow: the cover itself is clear.
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setBlendMode(.clear)
            context.addPath(shape)
            context.fillPath()
            return true
        }
        images[key] = image
        return image
    }
}

/// A clip that cuts the sides at the view's bounds but lets content bleed
/// a little past the top and bottom.
private struct VerticalBleed: Shape {
    let top: CGFloat
    let bottom: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - top, width: rect.width, height: rect.height + top + bottom))
    }
}

/// Marks the start of a year or genre, like a record-bin divider: a card
/// that stands behind the covers, its labelled tab rising above them.
private struct DividerCard: View {
    static let tabHeight: CGFloat = 24

    let label: String
    let height: CGFloat

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .heavy).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .frame(minWidth: 30, maxHeight: .infinity, alignment: .top)
            .frame(height: height)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                    .fill(Theme.surfaceElevated)
            )
            .fixedSize(horizontal: true, vertical: false)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Album info

/// The selected album, below the shelf: title, credits, fidelity, its place
/// in the deck and playback.
private struct ShelfAlbumInfo: View, Equatable {
    let album: Album
    let position: String
    let play: (_ shuffle: Bool) -> Void

    /// By identity, like `ShelfCover`: comparing whole albums is costly.
    /// `play` reads the album it's given, so it needn't be compared.
    nonisolated static func == (lhs: ShelfAlbumInfo, rhs: ShelfAlbumInfo) -> Bool {
        lhs.album.id == rhs.album.id
            && lhs.album.name == rhs.album.name
            && lhs.album.artist == rhs.album.artist
            && lhs.album.albumArtist == rhs.album.albumArtist
            && lhs.album.year == rhs.album.year
            && lhs.album.genre == rhs.album.genre
            && lhs.album.trackCount == rhs.album.trackCount
            && lhs.position == rhs.position
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 10) {
                Text(album.name)
                    .font(.system(size: 52, weight: .heavy))
                    .tracking(-1.8)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    Text(details)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let quality = album.qualitySummary {
                        Text(quality.text)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(quality.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(quality.color.opacity(0.12)))
                    }
                }
            }
            .id(album.id)
            .transition(.opacity.combined(with: .offset(y: 6)))

            Spacer(minLength: Theme.Spacing.lg)

            Text(position)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .contentTransition(.numericText())

            Button { play(false) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(FLActionPillStyle(isPrimary: true))
            Button { play(true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(FLActionPillStyle())
        }
        .frame(height: ShelfMetrics.detailsHeight, alignment: .top)
        .animation(.easeOut(duration: 0.3), value: album.id)
    }

    private var details: String {
        var parts: [String] = []
        if album.isCompilation {
            parts.append("Compilation")
        } else if let artist = ArtistResolver.displayString(album.albumArtist ?? album.artist) {
            parts.append(artist)
        }
        if let year = album.year { parts.append(String(year)) }
        if let genre = album.genre { parts.append(genre) }
        return parts.joined(separator: " · ")
    }
}
