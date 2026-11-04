import SwiftUI
import AppKit

/// The Collection tab's album rack: every album as a CD spine, side by side
/// on one long shelf that scrolls sideways (wheel or trackpad, either axis). Each spine carries a slice of its album's art under clear
/// plastic, with a paper insert printed with the title and artist (see
/// `SpineDesign`); a small tab above the
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
/// window are built; each spine's art is cut (or blurred) once off the main
/// thread and reused; nothing is masked or blurred live while it scrolls (the
/// rack only blurs behind a case taken out); the ends fade with
/// gradients painted over the rack rather than a mask.
struct AlbumRackView: View {
    /// Already sorted and filtered by the Collection page.
    let albums: [Album]
    /// Changes whenever `albums` is rebuilt, including for edits that keep
    /// every album's ID (a new label or genre).
    let revision: Int
    let sort: CollectionSortOption
    /// The space the page has for the rack.
    let available: CGSize
    let open: (Album) -> Void
    let contextMenu: (Album) -> [FLContextMenuItem]

    @Environment(PlayerState.self) private var player
    @Environment(ListeningStore.self) private var listening
    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// How far the rack is scrolled, in points.
    @State private var scrollX: CGFloat = 0
    @State private var hoveredID: String?
    /// Where the clear-case sheen sits down the hovered spine. Kept in its
    /// own object that only the sheen reads, so following the pointer
    /// doesn't redraw the rack.
    @State private var pointer = RackPointer()
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
    /// How far the taken-out spine was lifted by hover when clicked, so the
    /// case leaves from where the spine was drawn rather than its slot.
    @State private var takenLift: CGFloat = 0
    @State private var sequence: Task<Void, Never>?
    /// The album whose spine is open in Edit Spine.
    @State private var editingSpine: Album?

    private var isOut: Bool { stage == .open }

    private var metrics: RackMetrics {
        var metrics = RackMetrics(available: available)
        metrics.liftsOnHover = UIStyle.shared.rackLiftOnHover
        return metrics
    }

    private var layoutKey: RackLayout.Key {
        RackLayout.Key(revision: revision, sort: sort, metrics: metrics)
    }

    private var layout: RackLayout {
        cachedLayout.key == layoutKey ? cachedLayout : RackLayout(albums: albums, revision: revision, sort: sort, metrics: metrics, resolver: library.makeArtistResolver())
    }

    var body: some View {
        let metrics = metrics
        let layout = layout
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                rack(metrics, layout: layout)
                readout(metrics, layout: layout)
            }
                // No blur: a blur over the whole shelf (every visible spine)
                // re-rendered offscreen on each frame the case moved over it.
                // Fading further and shrinking a touch reads as just as far back.
                .opacity(shelfReceded ? 0.12 : 1)
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
        .sheet(item: $editingSpine) { album in
            EditSpineSheet(album: album, credit: credit(album), artists: artists(album))
        }
        .onChange(of: layoutKey, initial: true) {
            cachedLayout = Perf.measure("Rack layout") { RackLayout(albums: albums, revision: revision, sort: sort, metrics: metrics, resolver: library.makeArtistResolver()) }
            scrollX = clampedScroll(scrollX, layout: cachedLayout)
        }
    }

    // MARK: - Rack

    private func rack(_ metrics: RackMetrics, layout: RackLayout) -> some View {
        // Until the spine faces are registered (a moment after launch) a
        // spine would set its title in a stand-in face and keep it, so the
        // shelf waits for them.
        let visible = SpineFontsState.shared.isReady
            ? Self.block(layout.visibleRange(from: scrollX - metrics.spineWidth * 2, to: scrollX + available.width), count: layout.albums.count)
            : 0..<0
        return ZStack(alignment: .topLeading) {
            // Everything inside slides together with one offset. The shelf
            // is its own view, compared by what it shows: a scroll step only
            // moves this offset, and the spines are rebuilt only when a new
            // block of them comes into range.
            RackShelf(
                layout: layout,
                visible: visible,
                metrics: metrics,
                hoveredID: hoveredID,
                takenOutID: takenOut?.id,
                pointer: pointer,
                takeOut: { index in takeOut(layout.albums[index], at: spineFrame(index, layout: layout, metrics: metrics)) }
            )
            .equatable()
            .offset(x: collectionGutter - scrollX)

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
                            pointer.sheenY = y
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 1)) { pointer.sheenY = y }
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
        .help(hoveredID.flatMap(layout.index(of:)).map { "\(layout.albums[$0].name) — \(layout.credits[$0])" } ?? "")
        .flContextMenu {
            guard let index = hoveredID.flatMap(layout.index(of:)) else { return [] }
            let album = layout.albums[index]
            return contextMenu(album) + spineMenu(album)
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

    /// The album's spine, rolled from its tags, its shuffle count and the
    /// person's spine settings.
    private func design(_ album: Album, credit: String, options: SpineDesign.Options? = nil) -> SpineDesign {
        SpineDesignCache.shared.design(
            for: album, credit: credit, shuffles: settings.spineShuffles[album.id] ?? 0, options: options ?? settings.spineOptions,
            overrides: settings.spineOverrides[album.id] ?? SpineOverrides(), artists: artists(album)
        )
    }

    /// The album's artists, one name each, as the rack's layout split them.
    private func artists(_ album: Album) -> [String] {
        layout.index(of: album.id).map { layout.artists[$0] } ?? []
    }

    /// The album's folder, where a real spine scan would sit, when scans are on.
    private func scanFolder(_ album: Album) -> URL? {
        settings.useSpineScans ? album.tracks.first?.url.deletingLastPathComponent() : nil
    }

    /// Edit Spine opens the sheet; Shuffle Spine rolls whatever wasn't picked
    /// there (one stored count); Reset Spine forgets both. Designed spines only.
    private func spineMenu(_ album: Album) -> [FLContextMenuItem] {
        guard settings.spineStyle == .designed else { return [] }
        let shuffles = settings.spineShuffles[album.id] ?? 0
        let isCustomised = shuffles > 0 || !(settings.spineOverrides[album.id]?.isEmpty ?? true)
        var items: [FLContextMenuItem] = [
            .divider,
            .button("Edit Spine…", systemImage: "slider.horizontal.3") {
                editingSpine = album
            },
            .button("Shuffle Spine", systemImage: "shuffle") {
                settings.spineShuffles[album.id] = shuffles + 1
            },
        ]
        if isCustomised {
            items.append(.button("Reset Spine", systemImage: "arrow.uturn.backward") {
                settings.spineShuffles[album.id] = nil
                settings.spineOverrides[album.id] = nil
            })
        }
        return items
    }

    /// `range` widened to whole blocks of 12 spines, so the set of spines on
    /// the shelf changes once every dozen spines scrolled rather than every
    /// spine.
    static func block(_ range: Range<Int>, count: Int) -> Range<Int> {
        guard !range.isEmpty else { return range }
        let size = 12
        let lower = max(0, (range.lowerBound / size) * size)
        let upper = min(count, ((range.upperBound + size - 1) / size) * size)
        return lower..<max(lower, upper)
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
        let index = readoutID.flatMap(layout.index(of:))
            ?? playingIndex(layout)
            ?? layout.visibleRange(from: scrollX, to: scrollX + available.width).first
        if room >= 40, let index {
            let album = layout.albums[index]
            let full = room >= 104
            HStack(alignment: .lastTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    if full {
                        Text(album.year.map { "Album · " + String($0) } ?? "Album")
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
        return layout.index(ofTrack: current)
    }

    // MARK: - Taking a case out

    private func takeOut(_ album: Album, at spine: CGRect) {
        Perf.event("Rack take out", album.name)
        sequence?.cancel()
        takenLift = hoveredID == album.id ? metrics.hoverLift : 0
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
        Perf.event("Rack put back")
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
            // Taken from where hover lifted it; put back down into its slot.
            caseCentre = CGPoint(x: takenFrom.midX, y: takenFrom.midY - (isClosing ? 0 : takenLift))
            // Back into the slot: eased at both ends, so it glides home.
            caseMotion = reduceMotion ? .easeOut(duration: 0.25) : .timingCurve(0.45, 0, 0.25, 1, duration: CaseStage.pullDuration)
        case .pulled:
            caseScale = pulledScale
            // Drawn a little further out along the hover's own lift, so the
            // pull carries on the hover's motion instead of reversing it.
            caseCentre = CGPoint(x: takenFrom.midX, y: takenFrom.midY - metrics.hoverLift * 1.5)
            caseMotion = isClosing
                // Turning back to its spine, after the disc has gone in.
                ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.85).delay(0.2)
                // Out of the slot: an even ease, no snap at the start.
                : .timingCurve(0.33, 0, 0.2, 1, duration: CaseStage.pullDuration)
        case .open:
            caseScale = 1
            caseCentre = CGPoint(x: front.midX, y: front.midY)
            caseMotion = reduceMotion ? .easeOut(duration: 0.25) : openMotion
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
                    ? discMotion.delay(reduceMotion ? 0 : 0.5 * openStretch)
                    : .timingCurve(0.4, 0, 0.6, 1, duration: 0.35), value: isOut)

            RackBox(album: album, credit: credit(album), design: design(album, credit: credit(album)), size: size, depth: depth, shelfScale: restScale, clearCase: settings.clearCaseLook, blurArt: settings.blurSpineArt, style: settings.spineStyle, scanFolder: scanFolder(album), castsShadow: false, angle: isOut ? RackBox.restingAngle : 90)
                .scaleEffect(caseScale)
                // Already shadowed as the hovered spine was, so nothing pops on the
                // click; the shadow goes only as it settles back into its slot.
                // The box's only shadow (it draws none of its own here).
                .shadow(color: .black.opacity(stage == .shelf && (isClosing || takenLift == 0) ? 0 : 0.45), radius: 14, y: 10)
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

    /// The case turning to its front, and its disc sliding out: the app's
    /// ease-out over 0.9s and 0.8s by default, or UI for nerds' curve and length.
    private var openMotion: Animation {
        let style = UIStyle.shared
        return .timingCurve(style.rackOpenCurve.unitCurve(standard: MotionCurve.flactastic), duration: style.rackOpenDuration)
    }

    private var discMotion: Animation {
        let style = UIStyle.shared
        return .timingCurve(style.rackOpenCurve.unitCurve(standard: MotionCurve.flactastic), duration: style.rackOpenDuration * 0.8 / 0.9)
    }

    /// How much longer (or shorter) the open is than designed, for the delays around it.
    private var openStretch: Double { UIStyle.shared.rackOpenDuration / 0.9 }

    private func credit(_ album: Album) -> String { RackLayout.credit(of: album) }

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
            Text(album.year.map { "Album · " + String($0) } ?? "Album")
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
            Group {
                if album.isCompilation {
                    Text(credit)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ArtistLink(credit: album.albumArtist ?? album.artist,
                               font: .system(size: 17, weight: .semibold),
                               color: Theme.textSecondary)
                }
            }
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
    var hoverLift: CGFloat { liftsOnHover ? 18 : 0 }
    /// From UI for nerds; part of the metrics so a change rebuilds the rack.
    var liftsOnHover = true
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
        var revision = -1
        var sort: CollectionSortOption = .album
        var metrics: RackMetrics? = nil
    }

    private(set) var albums: [Album] = []
    /// Each album's display credit, worked out once rather than on every
    /// frame of a scroll.
    private(set) var credits: [String] = []
    private(set) var artists: [[String]] = []
    private(set) var tabs: [Tab] = []
    /// Each album's place on the rack, by ID, and by each of its tracks' IDs.
    private var indexByID: [String: Int] = [:]
    private var indexByTrack: [UUID: Int] = [:]
    private(set) var key = Key()
    private var pitch: CGFloat = 1

    init() {}

    /// The album's artists, one name apiece, for spines that set them apart
    /// with their own separator. A compilation is just that.
    static func artists(of album: Album, resolver: ArtistResolver?) -> [String] {
        if album.isCompilation { return ["Compilation"] }
        let raw = album.albumArtist ?? album.artist
        let names = resolver?.split(raw) ?? (raw.flatMap(ArtistResolver.explicitlySeparated) ?? [raw].compactMap { $0 })
        return names.isEmpty ? ["Unknown Artist"] : names
    }

    /// The name a spine and the case's details credit the album to.
    static func credit(of album: Album) -> String {
        album.isCompilation ? "Compilation" : (ArtistResolver.displayString(album.albumArtist ?? album.artist) ?? "Unknown Artist")
    }

    init(albums: [Album], revision: Int, sort: CollectionSortOption, metrics: RackMetrics, resolver: ArtistResolver? = nil) {
        key = Key(revision: revision, sort: sort, metrics: metrics)
        self.albums = albums
        artists = albums.map { Self.artists(of: $0, resolver: resolver) }
        indexByID = Dictionary(albums.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, album) in albums.enumerated() {
            for track in album.tracks where indexByTrack[track.id] == nil { indexByTrack[track.id] = index }
        }
        credits = albums.map(Self.credit(of:))
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
        case .label:
            groupOf = { $0.label ?? "No Label" }
        }
        // A group's tab is skipped when the one before it still covers its
        // first spine: many small groups (labels, genres) would otherwise
        // pile their tabs on top of each other. Long names are shortened.
        var last: String?
        var nextFree: CGFloat = -.infinity
        for (index, album) in albums.enumerated() {
            let group = groupOf(album)
            if group != last {
                let label = group.count > 22 ? String(group.prefix(21)) + "…" : group
                let x = CGFloat(index) * pitch
                if x >= nextFree {
                    tabs.append(Tab(label: label, firstIndex: index))
                    nextFree = x + Self.tabWidth(label) + 3
                }
            }
            last = group
        }
    }

    /// About how wide a tab's label runs at 11pt heavy, with its padding.
    private static func tabWidth(_ label: String) -> CGFloat {
        max(24, CGFloat(label.count) * 7.4 + 14)
    }

    /// A–Z for names starting with a letter, # for anything else.
    private static func initial(_ name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let letter = String(first).uppercased()
        return letter.rangeOfCharacter(from: .letters) != nil ? letter : "#"
    }

    var contentWidth: CGFloat { CGFloat(albums.count) * pitch }

    func index(of id: String) -> Int? { indexByID[id] }

    func index(ofTrack id: UUID) -> Int? { indexByTrack[id] }

    func x(of index: Int) -> CGFloat { CGFloat(index) * pitch }

    /// Spines overlapping `start..<end` in rack coordinates.
    func visibleRange(from start: CGFloat, to end: CGFloat) -> Range<Int> {
        guard !albums.isEmpty else { return 0..<0 }
        let lower = max(0, Int((start / pitch).rounded(.down)))
        let upper = min(albums.count, Int((end / pitch).rounded(.up)) + 1)
        return lower..<max(lower, upper)
    }
}

// MARK: - Shelf

/// The pointer's place down the hovered spine, for the sheen.
@MainActor
@Observable
final class RackPointer {
    var sheenY: CGFloat = 0
}

/// The spines on the rack (the visible block of them), their group tabs and
/// the hovered spine's sheen. Compared by what it shows, so scrolling, which
/// only moves it, doesn't rebuild it. It reads the spine settings itself, so
/// changing one still redraws it.
private struct RackShelf: View, Equatable {
    let layout: RackLayout
    let visible: Range<Int>
    let metrics: RackMetrics
    let hoveredID: String?
    let takenOutID: String?
    let pointer: RackPointer
    let takeOut: (Int) -> Void

    @Environment(Settings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: RackShelf, rhs: RackShelf) -> Bool {
        lhs.layout.key == rhs.layout.key
            && lhs.visible == rhs.visible
            && lhs.metrics == rhs.metrics
            && lhs.hoveredID == rhs.hoveredID
            && lhs.takenOutID == rhs.takenOutID
    }

    var body: some View {
        // Read once per redraw, not once per spine.
        let options = settings.spineOptions
        let hoveredIndex = hoveredID.flatMap(layout.index(of:))
        ZStack(alignment: .topLeading) {
            ForEach(layout.tabs.filter { visible.contains($0.firstIndex) }) { tab in
                RackTab(label: tab.label)
                    .offset(x: layout.x(of: tab.firstIndex), y: metrics.top - RackTab.height - 2)
            }
            ForEach(visible, id: \.self) { index in
                let album = layout.albums[index]
                let credit = layout.credits[index]
                let hovered = hoveredIndex == index
                RackSpine(
                    album: album,
                    credit: credit,
                    width: metrics.spineWidth,
                    height: metrics.spineHeight,
                    isHovered: hovered,
                    design: SpineDesignCache.shared.design(
                        for: album, credit: credit, shuffles: settings.spineShuffles[album.id] ?? 0, options: options,
                        overrides: settings.spineOverrides[album.id] ?? SpineOverrides(), artists: layout.artists[index]
                    ),
                    clearCase: settings.clearCaseLook,
                    blurArt: settings.blurSpineArt,
                    style: settings.spineStyle,
                    scanFolder: settings.useSpineScans ? album.tracks.first?.url.deletingLastPathComponent() : nil
                )
                .equatable()
                .offset(
                    x: layout.x(of: index),
                    y: metrics.top - (hovered ? metrics.hoverLift : 0)
                )
                .zIndex(hovered ? 1 : 0)
                .opacity(takenOutID == album.id ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(album.name), \(credit)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { takeOut(index) }
            }
            // The sheen on the hovered spine only, drawn apart from the
            // spines; following the pointer redraws nothing else.
            if settings.clearCaseLook, takenOutID == nil, let id = hoveredID, let index = hoveredIndex, visible.contains(index) {
                RackSheenHost(pointer: pointer, width: metrics.spineWidth, height: metrics.spineHeight)
                    .offset(x: layout.x(of: index), y: metrics.top - metrics.hoverLift)
                    .zIndex(2)
                    .id(id)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: hoveredID)
    }
}

/// Reads the pointer's place itself, so its moves redraw only the sheen.
private struct RackSheenHost: View {
    let pointer: RackPointer
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RackSheen(width: width, height: height, y: pointer.sheenY)
    }
}

// MARK: - Spine

/// One CD spine: a slice of the album's art with a paper insert on it,
/// carrying the title (in a face picked by genre) and the artist. Every
/// choice comes from the album's `SpineDesign`. In the clear-case look the
/// printed card sits just inside a plastic lid: a bright rim, lighter caps at
/// top and bottom, a hard highlight down the hinge side and, on older
/// albums, a few fine scuffs.
///
/// Drawn sideways in a canvas the spine's length wide, then turned upright,
/// so "top" is the canvas's leading edge.
struct RackSpine: View, Equatable {
    let album: Album
    let credit: String
    let width: CGFloat
    let height: CGFloat
    let isHovered: Bool
    var design: SpineDesign
    var clearCase: Bool = false
    var blurArt: Bool = false
    /// One shelf point in this spine's own points: above 1 when it's drawn
    /// large and scaled down (the case's spine face), so its rim, insets and
    /// print come out the same as on the shelf.
    var unit: CGFloat = 1
    /// Designed, or the art with or without a plain title.
    var style: SpineStyle = .designed
    /// The album's folder, when real spine scans should be used.
    var scanFolder: URL?
    /// The whole cover, for Edit Spine's preview: slid behind the spine to
    /// the design's slice instead of being cut, so dragging the art's
    /// position moves an image rather than cutting a new one each step.
    var fullCover: NSImage?
    /// Edit Spine's preview: reports where the strip, title, artist, label
    /// mark and disc count land (`spinePartReporter`), so they can be clicked.
    var reportsParts = false

    @Environment(\.displayScale) private var displayScale
    /// A real spine scan from the album's folder, which replaces the drawn spine.
    @State private var scan: NSImage?
    @State private var art: NSImage?
    /// Brightness of the art at the spine's top and bottom, for an artist
    /// printed straight onto it.
    @State private var artEnds: (top: Double, bottom: Double) = (0.2, 0.2)
    /// The cover's dominant colour, for an art-coloured insert.
    @State private var artSwatch: HomePalette.Swatch?

    /// The printed card's size: inset inside the lid in the clear-case look.
    private var printSize: CGSize {
        clearCase ? CGSize(width: width - 3 * unit, height: height - 6 * unit) : CGSize(width: width, height: height)
    }

    var body: some View {
        Group {
            if clearCase {
                ZStack {
                    Color(white: 0.07)
                    printed
                        .clipShape(RoundedRectangle(cornerRadius: unit))
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
        // Drawn into one layer: the art, insert, type, marks and lid become a
        // single finished image that scrolling just slides, rather than a
        // dozen layers composited afresh every frame. Redrawn only when the
        // spine itself changes.
        .drawingGroup()
        .shadow(color: .black.opacity(isHovered ? 0.6 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 12 : 0)
        .task(id: artKey) { await loadArt() }
        .task(id: scanFolder) { await loadScan() }
        .task(id: "\(album.artwork?.count ?? 0)|\(design.fill == .art)|\(design.artistLogos.compactMap { $0 }.joined())|\(design.labelLogo ?? "")") { await loadSwatch() }
    }

    // MARK: Card

    /// The printed card: art, then the insert and any marks on it.
    @ViewBuilder
    private var printed: some View {
        let size = printSize
        if let scan = shownScan {
            Image(nsImage: scan)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .allowsHitTesting(false)
        } else if style != .designed {
            plainCard(size)
        } else {
            designedCard(size)
        }
    }

    /// The art alone, or with the title and artist printed down it in white.
    private func plainCard(_ size: CGSize) -> some View {
        ZStack {
            Color(white: 0.12)
            if let art = shownArt {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            }
            if style == .artAndTitle {
                // A plain wash rather than a text shadow, so the print reads
                // on bright art at no per-frame cost.
                Color.black.opacity(isHovered ? 0.06 : 0.2)
                HStack(spacing: 6 * unit) {
                    Text(printedTitle)
                        .font(.system(size: 12.5 * unit, weight: .heavy))
                    Text(credit)
                        .font(.system(size: 12.5 * unit, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: max(0, size.height - 28 * unit), alignment: .leading)
                .rotationEffect(.degrees(90))
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func designedCard(_ size: CGSize) -> some View {
        ZStack {
            Color(white: 0.12)
            if let fullCover {
                slidingCover(fullCover, size: size)
            } else if let art = shownArt {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            }
            // Blurred art keeps the old wash, so the print still reads on it.
            if blurArt {
                Color.black.opacity(isHovered ? 0.06 : 0.2)
            }
            ZStack {
                if design.artistOnArt, !design.isLong, shows(.artist) {
                    // The artist and the strip share the spine's length, so a
                    // long title truncates rather than running under the name.
                    let top = design.artistEnd == .top
                    HStack(spacing: 10 * unit) {
                        if top { artistOnArt.padding(.leading, 14 * unit + head) }
                        if hasStripContent {
                            strip(length: size.height, across: size.width, reservesHead: !top, reservesFoot: top)
                        } else {
                            Spacer(minLength: 0)
                        }
                        if !top { artistOnArt.padding(.trailing, 14 * unit + foot) }
                    }
                } else if hasStripContent {
                    strip(length: size.height, across: size.width)
                }
                labelMark(across: size.width)
            }
            .frame(width: size.height, height: size.width)
            .rotationEffect(.degrees(90))
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func shows(_ element: SpineElement) -> Bool { !design.hidden.contains(element) }

    /// The art to draw: this spine's own slice, or until it's cut, the same
    /// slice already cut at another size (the shelf's, when the case is
    /// lifted off), so a spine at a new size never draws blank.
    private var shownArt: NSImage? {
        if let art { return art }
        if blurArt { return BlurredArtworkCache.shared.cached(id: "rack-spine:\(album.id)") }
        guard let data = album.artwork, !data.isEmpty else { return nil }
        return SpineArtCache.shared.anySize(SpineArtCache.sizeFreeKey(data: data, slice: design.slice, age: design.age))?.image
    }

    private var shownScan: NSImage? {
        scan ?? scanFolder.flatMap(SpineScanCache.shared.anySize(folder:))
    }

    /// The whole cover at the spine's height, slid so the design's slice
    /// shows, faded with age the way a cut slice would be.
    private func slidingCover(_ cover: NSImage, size: CGSize) -> some View {
        let coverWidth = size.height * cover.size.width / max(cover.size.height, 1)
        let travel = max(0, coverWidth - size.width)
        return Image(nsImage: cover)
            .resizable()
            .interpolation(.medium)
            .frame(width: coverWidth, height: size.height)
            .saturation(1 - design.age * 0.35)
            .offset(x: -travel * design.slice + (coverWidth - size.width) / 2)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// Whether anything is left to print on the insert once hidden parts are
    /// taken off: with the title, the artist on the card and the disc count
    /// all gone, there's no insert at all.
    private var hasStripContent: Bool {
        shows(.title) || (shows(.artist) && !design.artistOnArt) || design.discCount > 1
    }

    /// Type printed straight on the art (the insert hidden): black or white
    /// by how light the art is, with a soft halo to lift it off.
    private var bareInk: Color {
        (artEnds.top + artEnds.bottom) / 2 > 0.6 && !blurArt ? Color(white: 0.07) : .white
    }

    /// The label's logo when it's shown without its badge or band.
    private var bareLabelLogo: SpineLogoStore.Logo? {
        design.labelLogoBacking ? nil : design.labelLogo.flatMap(SpineLogoStore.logo)
    }

    /// How far a bare label logo may run along the spine: an upright one
    /// stands within the spine's width, a turned one lies along it.
    private var bareLogoAlong: CGFloat {
        (design.labelLogoRotation == .upright ? 24 : 34) * unit
    }

    /// A logo fitted within `along` (down the spine) by `across`, facing
    /// `rotation` as seen on the shelf. The spine is drawn sideways and
    /// turned upright, so Right is the logo as drawn, Left half a turn more,
    /// and Upright a quarter turn back.
    @ViewBuilder
    private func rotatedLogo(_ logo: SpineLogoStore.Logo, color: Color?, rotation: LogoRotation, along: CGFloat, across: CGFloat) -> some View {
        let aspect = logo.image.size.width / max(logo.image.size.height, 1)
        switch rotation {
        case .right, .left:
            let width = min(along, across * aspect)
            logoImage(logo, color: color, height: width / max(aspect, 0.01), maxWidth: width)
                .rotationEffect(.degrees(rotation == .left ? 180 : 0))
        case .upright:
            // Seen upright, its width runs across the spine.
            let width = min(across, along * aspect)
            let height = width / max(aspect, 0.01)
            logoImage(logo, color: color, height: height, maxWidth: width)
                .rotationEffect(.degrees(-90))
                .frame(width: height, height: width)
        }
    }

    /// Room the label mark takes at its end of the spine.
    private var markRoom: CGFloat {
        guard let mark = design.mark else { return 0 }
        if bareLabelLogo != nil { return bareLogoAlong + 10 * unit }
        if mark.kind == .band { return 30 * unit }
        return (Self.markSize(mark.shape).width + 8) * unit
    }

    /// Room kept clear at the top and the foot for the label mark.
    private var head: CGFloat { design.mark?.end == .top ? markRoom : 0 }
    private var foot: CGFloat { design.mark?.end == .bottom ? markRoom : 0 }

    /// The paper insert, placed upper, centre or lower in the room it's
    /// given. `reservesHead`/`reservesFoot` keep it clear of the label mark;
    /// off at an end something else (an artist on the art) already holds.
    private func strip(length: CGFloat, across: CGFloat, reservesHead: Bool = true, reservesFoot: Bool = true) -> some View {
        let fill = resolvedFill
        let bare = !shows(.insert)
        let ink = bare ? bareInk : inkColor(on: fill)
        let margin = (design.isLong ? 10 : 14) * unit
        let alignment: Alignment = design.position == .top ? .leading : design.position == .bottom ? .trailing : .center
        return stripBody(ink: ink, length: length)
            .frame(height: across)
            .shadow(color: bare ? (ink == .white ? .black.opacity(0.75) : .white.opacity(0.5)) : .clear, radius: 2 * unit)
            .background { if !bare { paper(fill, ink: ink) } }
            // Only a torn edge needs a clipping mask; a straight one is
            // already its own rectangle.
            .modifier(TornClip(isTorn: !bare && design.edge == .torn, seed: design.detailSeed, depth: 3.2 * unit))
            .spinePart(.insert, reportsParts)
            .rotationEffect(.degrees(design.askew))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.leading, (design.position == .top ? margin : 0) + (reservesHead && design.position != .bottom ? head : 0))
            .padding(.trailing, (design.position == .bottom ? margin : 0) + (reservesFoot && design.position != .top ? foot : 0))
    }

    @ViewBuilder
    private func stripBody(ink: Color, length: CGFloat) -> some View {
        // Both sizes hug their text so the cover shows around them; a long
        // insert just gives it more room, up to most of the spine.
        if design.isLong {
            WidthCap(cap: max(0, length * 0.78 - head - foot)) {
                HStack(spacing: 12 * unit) {
                    if shows(.title) { title(ink: ink) }
                    if shows(.artist) { artist(ink: ink) }
                }
                .padding(.horizontal, 18 * unit)
            }
        } else {
            WidthCap(cap: max(0, length - 28 * unit - head - foot)) {
                HStack(spacing: 6 * unit) {
                if shows(.title) { title(ink: ink) }
                if !design.artistOnArt, shows(.artist) {
                    if shows(.title) { separator(ink: ink) }
                    artist(ink: ink)
                }
                if design.discCount > 1 {
                    Text("\(design.discCount) CD")
                        .font(.system(size: 8 * unit, weight: .bold))
                        .tracking(0.5 * unit)
                        .foregroundStyle(ink.opacity(0.7))
                        .padding(.horizontal, 3 * unit)
                        .padding(.vertical, 1 * unit)
                        .overlay(RoundedRectangle(cornerRadius: 2 * unit).strokeBorder(ink.opacity(0.7), lineWidth: unit))
                        .fixedSize()
                        .spinePart(.discCount, reportsParts)
                }
            }
            .padding(.horizontal, 8 * unit)
            }
        }
    }

    /// Matte paper: darker at the folds along each side, and, ruled, a
    /// hairline down each.
    private func paper(_ fill: Color, ink: Color) -> some View {
        ZStack {
            fill
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.08), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.78),
                    .init(color: .black.opacity(0.1), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            if design.edge == .ruled {
                VStack(spacing: 0) {
                    Rectangle().frame(height: unit)
                    Spacer(minLength: 0)
                    Rectangle().frame(height: unit)
                }
                .foregroundStyle(ink.opacity(0.42))
                .padding(.vertical, 2.5 * unit)
            }
        }
    }

    private func title(ink: Color) -> some View {
        let caps = design.lettering == .caps || design.lettering == .acronym
        let base: CGFloat = 12.5 * unit * (caps ? 0.9 : 1)
        let font: Font
        let tracking: CGFloat
        var raise: CGFloat = 0
        if let face = design.font {
            font = .custom(face.postScriptName, size: base * face.scale)
            tracking = (face.tracking + (caps ? 0.04 : 0)) * base * face.scale
            raise = SpineFonts.capCentring(face) * base * face.scale
        } else {
            font = .system(size: base, weight: .heavy)
            tracking = caps ? 0.04 * base : 0
        }
        return Text(printedTitle)
            .font(font)
            .tracking(tracking)
            .textCase(textCase)
            .foregroundStyle(ink)
            .lineLimit(1)
            .offset(y: -raise)
            .spinePart(.title, reportsParts)
    }

    /// The design's title text; a design rolled before it had one prints the
    /// album's.
    private var printedTitle: String { design.title.isEmpty ? album.name : design.title }

    private func artist(ink: Color) -> some View {
        artistLine(ink: ink.opacity(0.78), ground: Self.luminance(NSColor(resolvedFill)), weight: .medium, logoHeight: 11 * unit)
            .spinePart(.artist, reportsParts)
    }

    /// The album's artists, each as their logo if the person added one or
    /// their name otherwise, set apart by the spine's artist separator (×),
    /// never commas.
    private func artistLine(ink: Color, ground: Double, weight: Font.Weight, logoHeight: CGFloat) -> some View {
        let names = design.artists.isEmpty ? [credit] : design.artists
        return HStack(spacing: 4 * unit) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                if i > 0 {
                    Text("×")
                        .font(.system(size: 9 * unit, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.7))
                        .accessibilityHidden(true)
                }
                if let file = design.artistLogos.indices.contains(i) ? design.artistLogos[i] : nil,
                   let logo = SpineLogoStore.logo(file) {
                    logoImage(logo, color: logoColor(design.artistLogoTints.indices.contains(i) ? design.artistLogoTints[i] : .auto, on: ground),
                              height: logoHeight, maxWidth: 80 * unit)
                        .accessibilityLabel(name)
                } else {
                    Text(name)
                        .font(.system(size: 10.5 * unit, weight: weight))
                        .textCase(textCase)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize()
    }

    /// A logo the person added, fitted to `height` along the spine: printed in
    /// `color`, or in its own colours when that's nil (Original, or a logo
    /// with no transparent background to print through).
    private func logoImage(_ logo: SpineLogoStore.Logo, color: Color?, height: CGFloat, maxWidth: CGFloat) -> some View {
        let aspect = logo.image.size.width / max(logo.image.size.height, 1)
        let width = min(maxWidth, height * aspect)
        let tinted = logo.isCutOut && color != nil
        return Image(nsImage: logo.image)
            .renderingMode(tinted ? .template : .original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color ?? .white)
            .frame(width: width, height: width / max(aspect, 0.01))
            .accessibilityLabel(credit)
    }

    /// The colour for a logo set to `tint`, on a ground of luminance `ground`.
    /// Auto tries white, black and the cover's colour in the album's own
    /// rolled order and takes the first that reads (3:1 or better), else
    /// whichever reads best.
    private func logoColor(_ tint: LogoTint, on ground: Double) -> Color? {
        let white = (Color.white, 1.0)
        let black = (Color(white: 0.07), 0.006)
        let cover: (Color, Double)? = artSwatch.map { s in
            let c = NSColor(hue: s.hue, saturation: min(s.saturation, 0.9), brightness: min(max(s.brightness, 0.3), 0.95), alpha: 1)
            return (Color(nsColor: c), Self.luminance(c))
        }
        switch tint {
        case .original: return nil
        case .white: return white.0
        case .black: return black.0
        case .cover: return (cover ?? white).0
        case .auto:
            let pool = [white, black] + (cover.map { [$0] } ?? [])
            let start = min(pool.count - 1, Int(design.logoTintRoll * Double(pool.count)))
            let ordered = (0..<pool.count).map { pool[(start + $0) % pool.count] }
            func contrast(_ l: Double) -> Double { (max(l, ground) + 0.05) / (min(l, ground) + 0.05) }
            return (ordered.first { contrast($0.1) >= 3 } ?? ordered.max { contrast($0.1) < contrast($1.1) })?.0
        }
    }

    @ViewBuilder
    private func separator(ink: Color) -> some View {
        switch design.separator {
        case .none:
            EmptyView()
        case .dot, .slash:
            Text(design.separator == .dot ? "•" : "/")
                .font(.system(size: 10 * unit))
                .foregroundStyle(ink.opacity(0.6))
                .fixedSize()
        case .rule:
            Rectangle()
                .fill(ink.opacity(0.45))
                .frame(width: unit, height: 12 * unit)
        }
    }

    private var textCase: Text.Case? {
        switch design.lettering {
        case .tagged, .acronym: return nil
        case .caps: return .uppercase
        case .lower: return .lowercase
        }
    }

    /// The artist printed straight onto the art at the strip's free end, in
    /// black or white by how light the art is there.
    private var artistOnArt: some View {
        let top = design.artistEnd == .top
        let light = (top ? artEnds.top : artEnds.bottom) > 0.6 && !blurArt
        return artistLine(ink: light ? Color(white: 0.07) : .white, ground: top ? artEnds.top : artEnds.bottom,
                          weight: .semibold, logoHeight: 12 * unit)
        .shadow(color: light ? .white.opacity(0.5) : .black.opacity(0.75), radius: 2 * unit, y: light ? 0 : unit)
        .spinePart(.artist, reportsParts)
        .layoutPriority(1)
    }

    /// The mark's face: the label's own logo when the person added one,
    /// otherwise its initials in the mark's type.
    @ViewBuilder
    private func markFace(_ mark: SpineDesign.Mark, ink: Color, size: CGFloat, fit: CGSize) -> some View {
        if let logo = design.labelLogo.flatMap(SpineLogoStore.logo) {
            rotatedLogo(logo, color: logoColor(design.labelLogoTint, on: Self.markGroundLuminance(mark)),
                        rotation: design.labelLogoRotation, along: fit.width, across: fit.height)
        } else {
            Text(mark.monogram)
                .font(Self.markFont(mark.face, size: size))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// The record label's mark at the top or foot: a monogram on a small
    /// shape, or a band across the spine, drawn the label's own way.
    @ViewBuilder
    private func labelMark(across: CGFloat) -> some View {
        if let mark = design.mark, let logo = bareLabelLogo {
            // The label's logo on its own, straight on the art, in a colour
            // that reads against the art at that end.
            let top = mark.end == .top
            let ground = top ? artEnds.top : artEnds.bottom
            rotatedLogo(logo, color: logoColor(design.labelLogoTint, on: ground), rotation: design.labelLogoRotation,
                        along: bareLogoAlong, across: min(across - 6 * unit, 18 * unit))
                .shadow(color: ground > 0.6 ? .white.opacity(0.4) : .black.opacity(0.6), radius: 1.5 * unit)
                .spinePart(.labelMark, reportsParts)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: top ? .leading : .trailing)
                .padding(top ? .leading : .trailing, 6 * unit)
        } else if let mark = design.mark {
            let colors = Self.markColors(mark)
            let alignment: Alignment = mark.end == .top ? .leading : .trailing
            switch mark.kind {
            case .badge:
                let size = Self.markSize(mark.shape)
                markFace(mark, ink: colors.ink, size: (mark.shape == .diamond ? 6.5 : 7.5) * unit,
                         fit: CGSize(width: size.width * 0.66 * unit, height: size.height * 0.56 * unit))
                    .tracking(-0.15 * unit)
                    .frame(width: size.width * unit, height: size.height * unit)
                    .background(MarkShape(shape: mark.shape, corner: 4 * unit).fill(colors.ground))
                    .overlay(MarkShape(shape: mark.shape, corner: 4 * unit)
                        .strokeBorder(colors.ring, lineWidth: (mark.style == .ringed ? 1.2 : 0.5) * unit))
                    .spinePart(.labelMark, reportsParts)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(mark.end == .top ? .leading : .trailing, 6 * unit)
            case .band:
                markFace(mark, ink: colors.ink, size: 8 * unit, fit: CGSize(width: 18 * unit, height: across * 0.6))
                    .tracking(0.3 * unit)
                    .frame(width: 24 * unit, height: across)
                    .background(colors.ground)
                    .overlay(alignment: mark.end == .top ? .trailing : .leading) {
                        if mark.style == .ringed { Rectangle().fill(colors.ring).frame(width: unit) }
                    }
                    .spinePart(.labelMark, reportsParts)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            }
        }
    }

    /// A badge's size in shelf points, along the spine by across it.
    static func markSize(_ shape: SpineDesign.Mark.Shape) -> CGSize {
        switch shape {
        case .circle, .rounded: return CGSize(width: 18, height: 18)
        case .square: return CGSize(width: 16, height: 16)
        case .pill: return CGSize(width: 28, height: 15)
        case .diamond: return CGSize(width: 21, height: 21)
        }
    }

    static func markFont(_ face: SpineDesign.Mark.Face, size: CGFloat) -> Font {
        switch face {
        case .heavy: return .system(size: size, weight: .heavy)
        case .rounded: return .system(size: size, weight: .black, design: .rounded)
        case .serif: return .system(size: size, weight: .bold, design: .serif)
        case .mono: return .system(size: size, weight: .bold, design: .monospaced)
        case .bungee: return .custom(SpineFont.bungee.postScriptName, size: size * 0.9)
        case .cinzel: return .custom(SpineFont.cinzel.postScriptName, size: size)
        }
    }

    /// Ground, type and ring colours for a mark's style.
    /// How light a mark's ground is, for a label logo printed on it.
    static func markGroundLuminance(_ mark: SpineDesign.Mark) -> Double {
        switch mark.style {
        case .filled: return luminance(houseColor(mark.hue))
        case .ringed: return 0.004
        case .inverted: return luminance(paperColor)
        }
    }

    static func markColors(_ mark: SpineDesign.Mark) -> (ground: Color, ink: Color, ring: Color) {
        let house = houseColor(mark.hue)
        switch mark.style {
        case .filled:
            let ink: Color = luminance(house) > 0.36 ? Color(white: 0.07) : .white
            return (Color(nsColor: house), ink, .black.opacity(0.4))
        case .ringed:
            let bright = Color(nsColor: NSColor(hue: mark.hue, saturation: 0.55, brightness: 0.95, alpha: 1))
            return (Color(white: 0.06), bright, bright)
        case .inverted:
            let deep = Color(nsColor: NSColor(hue: mark.hue, saturation: 0.75, brightness: 0.5, alpha: 1))
            return (Color(nsColor: paperColor), deep, .black.opacity(0.3))
        }
    }

    // MARK: Lid

    /// The clear lid over the card: caps, the hinge-side highlights and,
    /// with age, scuffs.
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
            if design.age > 0 {
                scuffs
            }
        }
        .allowsHitTesting(false)
    }

    /// A few faint hairline scratches and a little haze, placed by the
    /// album, showing more the older it is. Each scratch fades out at both
    /// ends and is softened slightly, so it reads as wear, not as lines.
    private var scuffs: some View {
        let seed = design.detailSeed, age = design.age, unit = unit
        return Canvas { context, size in
            var r = SpineRandom(seed: seed &+ 31)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.035 * age)))
            context.addFilter(.blur(radius: 0.35 * unit))
            for _ in 0..<3 {
                let angle = r.next() * .pi
                let length = (16 + r.next() * 36) * unit
                let center = CGPoint(x: r.next() * size.width, y: 20 * unit + r.next() * (size.height - 40 * unit))
                let dx = cos(angle) * length / 2, dy = sin(angle) * length / 2
                let start = CGPoint(x: center.x - dx, y: center.y - dy), end = CGPoint(x: center.x + dx, y: center.y + dy)
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                let peak = Color.white.opacity(0.2 * age)
                context.stroke(
                    line,
                    with: .linearGradient(Gradient(colors: [.clear, peak, .clear]), startPoint: start, endPoint: end),
                    lineWidth: 0.5 * unit
                )
            }
        }
    }

    // MARK: Colour

    private static let paperColor = NSColor(srgbRed: 0.949, green: 0.937, blue: 0.906, alpha: 1)
    private static let inkBlack = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.071, alpha: 1)

    private var resolvedFill: Color {
        var base: NSColor
        var isBlack = false
        switch design.fill {
        case .paper:
            base = Self.paperColor
        case .black:
            base = Self.inkBlack
            isBlack = true
        case .house(let hue):
            base = Self.houseColor(hue)
        case .custom(let hex):
            base = Self.color(hex: hex) ?? Self.paperColor
        case .art:
            // The cover's dominant colour, unless it's too grey to read as a
            // colour; then paper or black by how light it is.
            if let s = artSwatch, s.saturation * s.brightness >= 0.22 {
                base = NSColor(hue: s.hue, saturation: min(s.saturation, 0.9), brightness: min(max(s.brightness, 0.3), 0.95), alpha: 1)
            } else if let s = artSwatch, s.brightness < 0.4 {
                base = Self.inkBlack
                isBlack = true
            } else {
                base = Self.paperColor
            }
        }
        if design.age > 0 {
            // Paper yellows, black browns, colour fades towards cream.
            let toward = isBlack ? NSColor(srgbRed: 0.227, green: 0.204, blue: 0.173, alpha: 1)
                                 : NSColor(srgbRed: 0.839, green: 0.749, blue: 0.525, alpha: 1)
            let amount = design.age * (isBlack ? 0.55 : design.fill == .paper ? 0.7 : 0.3)
            base = base.blended(withFraction: amount, of: toward) ?? base
        }
        return Color(nsColor: base)
    }

    /// Black or white type, by how bright the strip under it is.
    private func inkColor(on fill: Color) -> Color {
        let light = Self.luminance(NSColor(fill)) > 0.36
        let aged = design.age
        if light {
            return Color(nsColor: Self.inkBlack.blended(withFraction: aged * 0.5, of: NSColor(srgbRed: 0.227, green: 0.173, blue: 0.11, alpha: 1)) ?? Self.inkBlack)
        }
        return Color(nsColor: NSColor.white.blended(withFraction: aged, of: NSColor(srgbRed: 0.937, green: 0.886, blue: 0.769, alpha: 1)) ?? .white)
    }

    /// "#rrggbb" as a colour.
    static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func houseColor(_ hue: Double) -> NSColor {
        NSColor(hue: hue, saturation: 0.6, brightness: 0.72, alpha: 1)
    }

    /// Relative luminance (WCAG), 0…1.
    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    // MARK: Loading

    private var artKey: String {
        "\(album.id)|\(album.artwork?.count ?? 0)|\(blurArt)|\(fullCover == nil ? design.slice : 0)|\(design.age)|\(Int(width * displayScale))x\(Int(height * displayScale))"
    }

    /// Sharp: the spine's own slice, cut and aged once off the main thread.
    /// Blurred: the cover blurred into a tiny bitmap and drawn scaled up. In
    /// both, no image work runs while the rack scrolls.
    private func loadArt() async {
        guard fullCover == nil, let data = album.artwork, !data.isEmpty else { return }
        if blurArt {
            let id = "rack-spine:\(album.id)"
            if let hit = BlurredArtworkCache.shared.cached(id: id) {
                art = hit
                return
            }
            let box = await BlurredArtworkCache.shared.image(for: data, id: id, maxPixel: 48, radius: 3)
            guard !Task.isCancelled else { return }
            art = box.image
            return
        }
        let pixels = CGSize(width: printSize.width * displayScale, height: printSize.height * displayScale)
        let key = SpineArtCache.key(data: data, slice: design.slice, pixelSize: pixels, age: design.age)
        let result: SpineArtCache.Art
        if let hit = SpineArtCache.shared.cached(key: key) {
            result = hit
        } else {
            result = await SpineArtCache.shared.art(for: data, key: key, slice: design.slice, pixelSize: pixels, age: design.age)
        }
        guard !Task.isCancelled else { return }
        art = result.image
        artEnds = (result.topLuminance, result.bottomLuminance)
    }

    private func loadScan() async {
        guard let folder = scanFolder else {
            scan = nil
            return
        }
        let pixels = Int(printSize.height * displayScale)
        if case let hit?? = SpineScanCache.shared.cached(folder: folder, pixelHeight: pixels) {
            scan = hit
            return
        }
        let image = await SpineScanCache.shared.scan(in: folder, pixelHeight: pixels)
        guard !Task.isCancelled else { return }
        scan = image
    }

    private func loadSwatch() async {
        // The cover's colour feeds an art-coloured insert and Auto logos.
        guard design.fill == .art || design.artistLogos.contains { $0 != nil } || design.labelLogo != nil else { return }
        if case let palette?? = CoverPalette.cached(for: album.artwork) {
            artSwatch = palette.swatches.first
            return
        }
        let palette = await CoverPalette.load(for: album.artwork)
        guard !Task.isCancelled else { return }
        artSwatch = palette?.swatches.first
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
            && lhs.design == rhs.design
            && lhs.clearCase == rhs.clearCase
            && lhs.blurArt == rhs.blurArt
            && lhs.unit == rhs.unit
            && lhs.style == rhs.style
            && lhs.scanFolder == rhs.scanFolder
            && lhs.fullCover === rhs.fullCover
            && lhs.reportsParts == rhs.reportsParts
    }
}

/// Where Edit Spine's preview hears where each part of the spine is drawn.
/// Frames are reported once layout is done, in the coordinate space the
/// preview names `SpinePartReporting.space`; nil when the part goes away.
/// Each drawn view reports under its own id, so a part that moves from one
/// view to another (the artist from the card to the art) can't have its new
/// place cleared by the old view going away afterwards.
struct SpinePartReporter: @unchecked Sendable {
    let report: (SpineElement, UUID, CGRect?) -> Void
}

enum SpinePartReporting {
    static let space = "spinePreview"
}

private struct SpinePartReporterKey: EnvironmentKey {
    static let defaultValue: SpinePartReporter? = nil
}

extension EnvironmentValues {
    var spinePartReporter: SpinePartReporter? {
        get { self[SpinePartReporterKey.self] }
        set { self[SpinePartReporterKey.self] = newValue }
    }
}

/// Reports this part's frame to the preview after layout. Measured with
/// onGeometryChange rather than read through a GeometryReader or anchor
/// preference, so the sheet's own sizing never depends on it.
private struct SpinePartModifier: ViewModifier {
    let element: SpineElement
    @Environment(\.spinePartReporter) private var reporter
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let reporter {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SpinePartReporting.space)) } action: { reporter.report(element, id, $0) }
                .onDisappear { reporter.report(element, id, nil) }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func spinePart(_ element: SpineElement, _ reports: Bool) -> some View {
        if reports {
            modifier(SpinePartModifier(element: element))
        } else {
            self
        }
    }
}

/// A label badge's outline.
private struct MarkShape: InsettableShape {
    let shape: SpineDesign.Mark.Shape
    let corner: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        switch shape {
        case .circle: return Circle().path(in: r)
        case .square: return Rectangle().path(in: r)
        case .rounded: return RoundedRectangle(cornerRadius: corner).path(in: r)
        case .pill: return Capsule().path(in: r)
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
            return p
        }
    }

    func inset(by amount: CGFloat) -> MarkShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Sizes its content to fit, never wider than `cap`. Unlike
/// `.frame(maxWidth:)`, which grows to the cap whenever there's room, this
/// keeps an insert as short as its text.
private struct WidthCap: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Clips an insert to its torn ends; leaves a straight-cut one unmasked.
private struct TornClip: ViewModifier {
    let isTorn: Bool
    let seed: UInt32
    let depth: CGFloat

    func body(content: Content) -> some View {
        if isTorn {
            content.clipShape(StripShape(torn: true, seed: seed, depth: depth))
        } else {
            content
        }
    }
}

/// The insert's outline: a plain rectangle, or with torn ends, the same tear
/// every time for a given seed.
private struct StripShape: Shape {
    let torn: Bool
    let seed: UInt32
    let depth: CGFloat

    func path(in rect: CGRect) -> Path {
        guard torn else { return Path(rect) }
        var r = SpineRandom(seed: seed)
        let steps = 6
        var path = Path()
        // Left end, top to bottom, then the right end, bottom to top.
        for k in 0...steps {
            let point = CGPoint(x: rect.minX + r.next() * depth, y: rect.minY + rect.height * CGFloat(k) / CGFloat(steps))
            k == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for k in (0...steps).reversed() {
            path.addLine(to: CGPoint(x: rect.maxX - r.next() * depth, y: rect.minY + rect.height * CGFloat(k) / CGFloat(steps)))
        }
        path.closeSubpath()
        return path
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

    static let pullDuration: Double = 0.45
    static let pullScale: CGFloat = 1.06
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
struct RackBox: View, Animatable {
    static let restingAngle: Double = -14

    let album: Album
    let credit: String
    let design: SpineDesign
    let size: CGFloat
    let depth: CGFloat
    /// The scale the box is shrunk to on the shelf, so its spine face's
    /// plastic matches the shelf spine it's swapped for, point for point.
    var shelfScale: CGFloat = 1
    var clearCase: Bool = false
    var blurArt: Bool = false
    var style: SpineStyle = .designed
    var scanFolder: URL?
    /// The front's drop shadow. Off while something moves the box every
    /// frame (Home's thrown case): a blurred shadow under a changing
    /// projection is re-rendered offscreen on each frame.
    var castsShadow: Bool = true
    var angle: Double

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if let spine = face(width: depth, turnedBy: -90, out: size / 2) {
                RackSpine(album: album, credit: credit, width: depth, height: size, isHovered: false, design: design, clearCase: clearCase, blurArt: blurArt, unit: 1 / max(shelfScale, 0.01), style: style, scanFolder: scanFolder)
                    .equatable()
                    .overlay { if clearCase, isSheenShowing { turnSheen(width: depth, reversed: true) } }
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

    /// The sweep shows only mid-turn. At rest it's gone from the tree: its
    /// blend mode costs an offscreen pass every frame even at zero strength.
    private var isSheenShowing: Bool { sin(.pi * Double(turnProgress)) > 0.02 }

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
                // One flat image: the projection then only moves a texture.
                .drawingGroup()
            }
        }
        .shadow(color: .black.opacity(castsShadow ? 0.5 : 0), radius: castsShadow ? 22 : 0, y: castsShadow ? 20 : 0)
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
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.35)).frame(height: 1) }
        // One flat image, so the projection only moves a texture; the
        // sweep (which changes every frame of the turn) sits on top of it.
        .drawingGroup()
        .overlay { if isSheenShowing { turnSheen(width: size) } }
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
/// turns slowly while its album plays. Also thrown onto the top of Home.
struct RackDisc: View {
    let album: Album
    /// Passed in rather than read here, so the disc redraws once they're
    /// sampled.
    let colors: [Color]
    let diameter: CGFloat
    let isSpinning: Bool
    /// Off while something moves the disc every frame under a projection
    /// (Home's thrown case); its shadow is otherwise drawn once with it.
    var castsShadow = true

    @State private var angle: Double = 0

    var body: some View {
        let print = (diameter * 0.64).rounded()
        let shadowRoom = castsShadow ? 48.0 : 0
        ZStack {
            // The silver and its shadow, drawn once into one image (with room
            // for the shadow), so sliding or turning the disc moves a texture
            // instead of re-blurring the shadow each frame.
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
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(castsShadow ? 0.5 : 0), radius: castsShadow ? 24 : 0, y: castsShadow ? 16 : 0)
                .padding(shadowRoom)
                .drawingGroup()
                .padding(-shadowRoom)
            // The print, as a ring around the hub: flattened, then spun as
            // an image while its album plays.
            RackDiscPrint(colors: colors, seed: seed, size: print)
                .mask {
                    Circle().strokeBorder(lineWidth: (print - diameter * 0.2) / 2)
                }
                .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5).frame(width: print, height: print))
                .drawingGroup()
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
