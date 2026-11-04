import SwiftUI

/// "UI for nerds": every appearance control beyond light and dark, in its own
/// window. The left of it is a live preview: the app's real pages drawn
/// small. Hover a part of the page and it outlines; click it and the
/// inspector on the right shows that part's controls (Esc, or the
/// breadcrumb, goes back up to the page's own). Every change saves at once
/// and shows in the preview and the main window together.
struct UIForNerdsView: View {
    @State private var page: NerdPage = .home
    @State private var selection: NerdPart?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("UI for nerds")
                    .font(.system(size: 20, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                FLPillToggle(selection: $page, segments: NerdPage.allCases.map { .text($0, $0.title) })
                Spacer(minLength: 12)
                Text("Click to inspect · Esc to go back up")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 80)   // clear of the traffic lights
            .padding(.trailing, 18)
            .frame(height: 52)
            Rectangle().fill(Theme.divider).frame(height: 1)

            HStack(spacing: 0) {
                NerdPreview(page: page, selection: $selection)
                    .padding(18)
                    .background(Theme.background.opacity(0.5))
                Rectangle().fill(Theme.divider).frame(width: 1)
                NerdInspector(page: page, selection: $selection)
                    .frame(width: 320)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(Theme.surface)
        .onChange(of: page) { _, page in selection = page == .player ? .player : nil }
        // Esc walks back up from a part to its page.
        .background {
            Button("") { selection = page == .player ? .player : nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }
}

// MARK: - Pages and parts

enum NerdPage: String, CaseIterable, Identifiable {
    case everywhere, home, collection, playlists, player, visualizer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .everywhere: "Everywhere"
        case .home: "Home"
        case .collection: "Collection"
        case .playlists: "Playlists"
        case .player: "Player bar"
        case .visualizer: "Visualizer"
        }
    }

    var lede: String {
        switch self {
        case .everywhere: "The look every page shares. Light and dark live in Settings › General."
        case .home: "Your front page as a whole. Click a part of it for more."
        case .collection: "Albums, as a rack of CDs or a grid of covers."
        case .playlists: "Your playlists, down the left of the page."
        case .player: "Tucked in the corner of every page; click it to open the full bar."
        case .visualizer: "Full-screen moods for whatever's playing."
        }
    }
}

/// A piece of a page the preview lets you click on.
enum NerdPart: String, Hashable {
    case homeTop, homeToday, homeShelves, homeMixes, homeRepeat, homeStats
    case collectionRack, collectionGrid, playlistsList, player

    var title: String {
        switch self {
        case .homeTop: "The top"
        case .homeToday: "Recommended for today"
        case .homeShelves: "Shelves"
        case .homeMixes: "Mixes"
        case .homeRepeat: "On repeat"
        case .homeStats: "Your listening"
        case .collectionRack: "The rack"
        case .collectionGrid: "Album grid"
        case .playlistsList: "Playlist list"
        case .player: "Player bar"
        }
    }

    var lede: String {
        switch self {
        case .homeTop: "The wordmark, today's lyric and the thrown jewel case."
        case .homeToday: "Today's pick and the rotation beside it."
        case .homeShelves: "Recently played, Jump back in, Recently added and the rest."
        case .homeMixes: "The playlists Home builds from your library."
        case .homeRepeat: "Your most-played tracks, last 30 days."
        case .homeStats: "The listening chart and the Fidelidex."
        case .collectionRack: "Every album as a CD spine on one long shelf."
        case .collectionGrid: "Albums as a grid of covers."
        case .playlistsList: "The column of playlists."
        case .player: "Tucked in the corner of every page; click it to open the full bar."
        }
    }

    var page: NerdPage {
        switch self {
        case .homeTop, .homeToday, .homeShelves, .homeMixes, .homeRepeat, .homeStats: .home
        case .collectionRack, .collectionGrid: .collection
        case .playlistsList: .playlists
        case .player: .player
        }
    }

    /// The part a Home section belongs to.
    static func home(_ section: HomeSection) -> NerdPart {
        switch section {
        case .recommended: .homeToday
        case .onRepeat: .homeRepeat
        case .mixes: .homeMixes
        case .listening, .fidelidex: .homeStats
        case .recentlyPlayed, .jumpBackIn, .timeOfDay, .recentlyAdded, .bestSounding: .homeShelves
        }
    }
}

// MARK: - Marking parts in the real views

extension EnvironmentValues {
    /// True inside the nerd window's preview, where pages report their parts.
    @Entry var isNerdPreview = false
}

struct NerdPartAnchor {
    let part: NerdPart
    let bounds: Anchor<CGRect>
}

struct NerdPartsKey: PreferenceKey {
    static let defaultValue: [NerdPartAnchor] = []
    static func reduce(value: inout [NerdPartAnchor], nextValue: () -> [NerdPartAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct NerdPartModifier: ViewModifier {
    let part: NerdPart
    @Environment(\.isNerdPreview) private var isPreview

    func body(content: Content) -> some View {
        if isPreview {
            content.anchorPreference(key: NerdPartsKey.self, value: .bounds) { [NerdPartAnchor(part: part, bounds: $0)] }
        } else {
            content
        }
    }
}

extension View {
    /// Marks this as a part UI for nerds can inspect. Costs nothing outside
    /// its preview.
    func nerdPart(_ part: NerdPart) -> some View { modifier(NerdPartModifier(part: part)) }
}

// MARK: - Preview

/// The page drawn at a desktop width (1440pt) and scaled to fit, with an
/// outline over each part it reports. The page itself doesn't take clicks:
/// the outlines do, so nothing navigates while you inspect.
private struct NerdPreview: View {
    let page: NerdPage
    @Binding var selection: NerdPart?

    @Environment(PlayerState.self) private var player
    @State private var hovered: Int?

    private static let width: CGFloat = 1440
    static let select = Color(red: 0.29, green: 0.64, blue: 1)

    private var height: CGFloat {
        switch page {
        case .home, .everywhere, .player: 2900
        case .collection: 1000
        case .playlists: 900
        case .visualizer: 0
        }
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / Self.width
            ZStack(alignment: UIStyle.shared.playerSide.bottomCorner) {
                if page == .visualizer {
                    visualizerNote
                } else {
                    ScrollView(.vertical) {
                        pageView
                            .environment(\.isNerdPreview, true)
                            .environment(\.topBarInset, TopBarView.height)
                            .frame(width: Self.width, height: height, alignment: .top)
                            .background(Theme.background)
                            .allowsHitTesting(false)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: geo.size.width, height: height * scale, alignment: .topLeading)
                            .overlayPreferenceValue(NerdPartsKey.self) { anchors in
                                GeometryReader { proxy in
                                    ForEach(Array(anchors.enumerated()), id: \.offset) { index, anchor in
                                        hotspot(index: index, part: anchor.part, rect: proxy[anchor.bounds])
                                    }
                                }
                            }
                    }
                    .scrollIndicators(.hidden)
                    puck(scale: scale)
                }
            }
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
            .overlay(alignment: .topTrailing) { liveBadge.padding(12) }
        }
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .home, .everywhere, .player: HomeView()
        case .collection: CollectionView()
        case .playlists: PlaylistsTabView()
        case .visualizer: EmptyView()
        }
    }

    /// The corner player, as it sits over every page, at the preview's scale.
    @ViewBuilder
    private func puck(scale: CGFloat) -> some View {
        if player.currentTrack != nil {
            let side = UIStyle.shared.playerSide
            let size = CGSize(width: CornerPlayerPuck.collapsedWidth * scale, height: CornerPlayerPuck.collapsedHeight * scale)
            CornerPlayerPuck(expandedWidth: UIStyle.shared.playerBarWidth)
                .allowsHitTesting(false)
                .scaleEffect(scale, anchor: side.unitBottomCorner)
                .frame(width: size.width, height: size.height, alignment: side.bottomCorner)
                .overlay { hotspot(index: -1, part: .player, rect: CGRect(origin: .zero, size: size)) }
                .padding(side == .left ? .leading : .trailing, Theme.Spacing.lg * scale)
                .padding(.bottom, 16 * scale)
        }
    }

    private func hotspot(index: Int, part: NerdPart, rect: CGRect) -> some View {
        let isSelected = selection == part
        let isHovered = hovered == index
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Color.white.opacity(0.001))
            .overlay {
                shape.strokeBorder(Self.select.opacity(isSelected ? 1 : (isHovered ? 0.8 : 0)),
                                   style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isSelected ? [] : [5, 4]))
            }
            .overlay(alignment: .topLeading) {
                if isHovered || isSelected {
                    Text(part.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Self.select, in: RoundedRectangle(cornerRadius: 5))
                        .offset(x: 4, y: -9)
                        .fixedSize()
                }
            }
            .frame(width: rect.width + 10, height: rect.height + 10)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(shape)
            .onHover { inside in
                if inside { hovered = index } else if hovered == index { hovered = nil }
            }
            .onTapGesture { selection = part }
            .help("Inspect \(part.title)")
            .accessibilityElement()
            .accessibilityLabel("Inspect \(part.title)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selection = part }
    }

    private var visualizerNote: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("The Visualizer fills the whole window, so it isn't drawn here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Text("Pick how it opens on the right.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.qualityCD).frame(width: 6, height: 6)
            Text(page == .visualizer ? "No preview" : "Live preview")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

// MARK: - Inspector

private struct NerdInspector: View {
    let page: NerdPage
    @Binding var selection: NerdPart?

    @Environment(Settings.self) private var settings
    @State private var showsGenreGroups = false

    var body: some View {
        let catalog = NerdCatalog(settings: settings, openGenreGroups: { showsGenreGroups = true })
        let groups = catalog.groups(page: page, part: selection)
        let all = catalog.allKnobs
        let changed = Set(all.filter { $0.isChanged() }.map(\.id)).count

        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.horizontal, 18)
                .padding(.top, 16)
            Text(selection?.title ?? page.title)
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 2)
            Text(selection?.lede ?? page.lede)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                            .padding(.bottom, 2)
                        ForEach(group.knobs) { $0.view }
                    }
                    if selection == nil, page != .everywhere, page != .visualizer {
                        Text("Point at something in the preview. Anything.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 8) {
                Text(changed == 0 ? "No tweaks yet" : "\(changed) tweak\(changed == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Button("Reset this") { groups.flatMap(\.knobs).forEach { $0.reset() } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!groups.flatMap(\.knobs).contains { $0.isChanged() })
                Button("Reset all") { all.forEach { $0.reset() } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(changed == 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
        }
        .background(Theme.surface)
        .sheet(isPresented: $showsGenreGroups) { GenreGroupsSheet() }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if let selection, selection != .player || page != .player {
                Button(page.title) { self.selection = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                Text("›").foregroundStyle(Theme.textTertiary)
                Text(selection.title).fontWeight(.bold).foregroundStyle(Theme.textPrimary)
            } else {
                Text(page.title).fontWeight(.bold).foregroundStyle(Theme.textPrimary)
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - Knobs

/// One control in the inspector, with what it takes to tell whether it's
/// been changed from its default and to put it back.
struct NerdKnob: Identifiable {
    let id: String
    let isChanged: () -> Bool
    let reset: () -> Void
    let view: AnyView
}

struct NerdGroup: Identifiable {
    let title: String
    let knobs: [NerdKnob]
    var id: String { title }
}

/// Every knob, grouped by page and part. Values UI for nerds adds live in
/// `UIStyle` (whose `pristine` copy holds the defaults); the rest are the
/// app's existing settings, moved here from Settings › Appearance.
@MainActor
private struct NerdCatalog {
    let settings: Settings
    let openGenreGroups: () -> Void
    private var style: UIStyle { .shared }

    func groups(page: NerdPage, part: NerdPart?) -> [NerdGroup] {
        if let part { return groups(part: part) }
        switch page {
        case .everywhere: return everywhere
        case .home: return [
            NerdGroup(title: "Sections", knobs: [arrangeAutomatically, sectionOrder]),
            NerdGroup(title: "Size & density", knobs: [density]),
        ]
        case .collection: return [NerdGroup(title: "Layout", knobs: [albumsOpenAs])]
        case .playlists: return [NerdGroup(title: "Size & density", knobs: [playlistSpacing])]
        case .player: return groups(part: .player)
        case .visualizer: return [NerdGroup(title: "Default", knobs: [visualizerOpensIn])]
        }
    }

    private func groups(part: NerdPart) -> [NerdGroup] {
        switch part {
        case .homeTop: return [
            NerdGroup(title: "Show", knobs: [
                toggle(\.homeShowCase, "Jewel case"),
                toggle(\.homeShowDate, "Today's date"),
                toggle(\.homeShowStory, "Where it's from", detail: "The album and year under the song."),
            ]),
            NerdGroup(title: "Size", knobs: [
                slider(\.caseScale, "Case size", 0.7...1.3, step: 0.05, unit: "×"),
                slider(\.lyricSize, "Lyric size", 34...64, step: 1, unit: "pt"),
            ]),
            NerdGroup(title: "Motion", knobs: [
                choice(\.caseThrow, "Throw the case", CaseThrow.allCases.map { ($0, $0.label) }),
                curve(\.throwCurve, "Curve", standard: "Thrown", standardShape: Self.thrownShape,
                      detail: "Thrown flies in fast and is caught with a jolt. The others are one smooth move into place."),
                slider(\.throwDuration, "Duration", 0.6...3, step: 0.1, unit: "s"),
                NerdKnob(id: "throwReplay", isChanged: { false }, reset: {},
                         view: AnyView(NerdButtonRow(label: "See it", detail: "Throws the case again here and in the main window.",
                                                     button: "Throw it again", action: { style.throwReplay += 1 }))),
            ]),
        ]
        case .homeToday: return [
            NerdGroup(title: "Layout", knobs: [choice(\.todayRows, "Rows beside today's pick", [(1, "One"), (2, "Two")]), coverSize]),
            NerdGroup(title: "Show", knobs: [captions, badges, subtitles]),
        ]
        case .homeShelves: return [
            NerdGroup(title: "Size", knobs: [coverSize]),
            NerdGroup(title: "Show", knobs: [captions, badges, subtitles]),
        ]
        case .homeMixes: return [
            NerdGroup(title: "Size", knobs: [slider(\.mixTileSize, "Largest tile", 210...360, step: 10, unit: "pt", detail: "Mixes grow to fill their row, up to this.")]),
            NerdGroup(title: "Colour", knobs: [slider(\.mixPhotoStrength, "Artist photo", 0...1, step: 0.05, unit: "%", detail: "How much of the photo shows under the mix's colour.")]),
        ]
        case .homeRepeat: return [
            NerdGroup(title: "Show", knobs: [
                choice(\.repeatRows, "Tracks", [(6, "6"), (8, "8"), (10, "10")]),
                toggle(\.repeatShowPlays, "Play counts"),
            ]),
        ]
        case .homeStats: return [NerdGroup(title: "Colour", knobs: [accentMode, accentColour])]
        case .collectionRack: return [
            NerdGroup(title: "Cases", knobs: [clearCase, toggle(\.rackLiftOnHover, "Lift on hover", detail: "The spine under the pointer rises out of the shelf.")]),
            NerdGroup(title: "Motion", knobs: [
                curve(\.rackOpenCurve, "Curve", standard: "Snappy", standardShape: MotionCurve.flactastic,
                      detail: "How a case taken off the rack turns to its front and lets its disc out. Snappy is fast away with a long, soft landing."),
                slider(\.rackOpenDuration, "Duration", 0.3...2, step: 0.05, unit: "s"),
            ]),
            NerdGroup(title: "Spines", knobs: spineKnobs),
        ]
        case .collectionGrid: return [NerdGroup(title: "Size", knobs: [slider(\.gridCoverSize, "Cover size", 140...260, step: 5, unit: "pt", detail: "The smallest a cover gets; they grow to fill each row.")])]
        case .playlistsList: return [NerdGroup(title: "Size & density", knobs: [playlistSpacing])]
        case .player: return [
            NerdGroup(title: "Position", knobs: [choice(\.playerSide, "Corner", PlayerSide.allCases.map { ($0, $0.label) },
                                                        detail: "Which bottom corner it sits in; it opens toward the middle.")]),
            NerdGroup(title: "Size", knobs: [slider(\.playerBarWidth, "Open bar width", 560...900, step: 10, unit: "pt", detail: "The widest the corner player opens.")]),
            NerdGroup(title: "Show", knobs: [
                toggle(\.playerCoverWash, "Cover wash on the glass"),
                toggle(\.playerQualityBadge, "Quality badge", detail: "Beside the title, in every player."),
                toggle(\.puckProgressLine, "Progress line", detail: "Along the closed player's lower edge."),
            ]),
        ]
        }
    }

    /// Every knob once, for the tweak count and Reset all.
    var allKnobs: [NerdKnob] {
        var seen = Set<String>()
        let pages = NerdPage.allCases.flatMap { groups(page: $0, part: nil) }
        let parts: [NerdPart] = [.homeTop, .homeToday, .homeShelves, .homeMixes, .homeRepeat, .homeStats,
                                 .collectionRack, .collectionGrid, .playlistsList, .player]
        return (pages + parts.flatMap { groups(part: $0) }).flatMap(\.knobs).filter { seen.insert($0.id).inserted }
    }

    // MARK: Everywhere

    private var everywhere: [NerdGroup] {
        [
            NerdGroup(title: "Colour & type", knobs: [
                accentMode, accentColour,
                toggle(\.tierColours, "Quality tier colours", detail: "Turquoise Hi-Res, green CD, amber Mid and red Low on badges and charts."),
                slider(\.sectionTitleSize, "Section title size", 16...32, step: 1, unit: "pt"),
            ]),
            NerdGroup(title: "Artwork", knobs: [
                slider(\.artworkRadius, "Corner radius", 0...24, step: 1, unit: "pt"),
                settingToggle("artworkShadow", "Drop shadows", get: { settings.showArtworkShadow }, set: { settings.showArtworkShadow = $0 }, default: true),
            ]),
            NerdGroup(title: "Motion & effects", knobs: [
                settingToggle("fadeAnimations", "Fade animations", get: { settings.fadeAnimationsEnabled }, set: { settings.fadeAnimationsEnabled = $0 }, default: true),
                settingChoice("fadeDirection", "Fade direction", FadeAnimationDirection.allCases.map { ($0, $0.label) },
                              get: { settings.fadeAnimationDirection }, set: { settings.fadeAnimationDirection = $0 }, default: .up,
                              isEnabled: settings.fadeAnimationsEnabled),
                slider(\.animationSpeed, "Animation speed", 0.5...2, step: 0.1, unit: "×", detail: "Above 1 is quicker."),
                toggle(\.glass, "Glass & glow", detail: "Frosted players, the cover wash and the glow behind Home's case."),
                toggle(\.launchFade, "Launch fade-in", detail: "Hide the window's chrome behind the loading screen and fade it in."),
                loadingAnimation,
            ]),
        ]
    }

    private var accentMode: NerdKnob {
        choice(\.accentMode, "Accent", AccentMode.allCases.map { ($0, $0.label) },
               detail: "Artist takes its colour from today's artist; Mono keeps Home black and white; Custom uses your colour.")
    }

    private var accentColour: NerdKnob {
        NerdKnob(id: "accentHex", isChanged: { style.accentHex != UIStyle.pristine.accentHex },
                 reset: { style.accentHex = UIStyle.pristine.accentHex },
                 view: AnyView(NerdColorRow(isChanged: style.accentHex != UIStyle.pristine.accentHex,
                                            reset: { style.accentHex = UIStyle.pristine.accentHex })))
    }

    private var loadingAnimation: NerdKnob {
        let d = UIStyle.pristine.loadingAnimation
        let changed = { style.loadingAnimation != d }
        return NerdKnob(id: "loadingAnimation", isChanged: changed, reset: { style.loadingAnimation = d },
                        view: AnyView(NerdLoaderPicker(isChanged: changed(), reset: { style.loadingAnimation = d })))
    }

    // MARK: Home

    private var arrangeAutomatically: NerdKnob {
        settingToggle("homeArranges", "Arrange automatically", detail: "Home's designed order, hiding what's empty. Turn off to choose your own.",
                      get: { settings.homeArrangesAutomatically }, set: { settings.homeArrangesAutomatically = $0 }, default: true)
    }

    private var sectionOrder: NerdKnob {
        let changed = { !settings.homeSectionOrder.isEmpty || !settings.homeHiddenSections.isEmpty }
        let reset = {
            settings.homeSectionOrder = []
            settings.homeHiddenSections = []
        }
        return NerdKnob(id: "homeOrder", isChanged: changed, reset: reset,
                        view: AnyView(NerdSectionOrder(isChanged: changed(), reset: reset)))
    }

    private var density: NerdKnob {
        slider(\.homeDensity, "Density", 8...32, step: 1, unit: "pt", detail: "Space between covers; sections get about 2.4× it. Left is compact, right is roomy.")
    }

    private var coverSize: NerdKnob { slider(\.homeCoverSize, "Cover size", 130...220, step: 5, unit: "pt", detail: "Shared by every shelf on Home.") }
    private var captions: NerdKnob { toggle(\.homeCaptions, "Titles under covers") }
    private var badges: NerdKnob { toggle(\.homeBadges, "Quality badges") }
    private var subtitles: NerdKnob { toggle(\.homeSubtitles, "Section subtitles") }

    // MARK: Collection

    private var albumsOpenAs: NerdKnob {
        let key = "flactastic.collectionAlbumView"
        let get = { AlbumViewStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .shelf }
        let set = { (v: AlbumViewStyle) in UserDefaults.standard.set(v.rawValue, forKey: key) }
        return NerdKnob(id: "albumsOpenAs", isChanged: { get() != .shelf }, reset: { set(.shelf) },
                        view: AnyView(NerdAlbumsOpenAs()))
    }

    private var clearCase: NerdKnob {
        settingToggle("clearCase", "Clear case look", detail: "CDs in clear plastic cases that catch the light as you move over them.",
                      get: { settings.clearCaseLook }, set: { settings.clearCaseLook = $0 }, default: true)
    }

    private var spineKnobs: [NerdKnob] {
        let designed = settings.spineStyle == .designed
        return [
            settingChoice("spineStyle", "Spine style", SpineStyle.allCases.map { ($0, $0.label) },
                          get: { settings.spineStyle }, set: { settings.spineStyle = $0 }, default: .designed,
                          detail: "Designed gives every album its own printed insert. The others show the cover's art down the spine."),
            settingToggle("spineScans", "Use spine scans", detail: "Show a real printed spine when the album's folder has one (spine.jpg).",
                          get: { settings.useSpineScans }, set: { settings.useSpineScans = $0 }, default: true),
            settingToggle("blurSpineArt", "Blur spine art", get: { settings.blurSpineArt }, set: { settings.blurSpineArt = $0 }, default: false),
            settingChoice("spineVariety", "Variety", SpineVariety.allCases.map { ($0, $0.label) },
                          get: { settings.spineVariety }, set: { settings.spineVariety = $0 }, default: .varied, isEnabled: designed),
            settingChoice("shelfTheme", "Shelf theme", ShelfTheme.allCases.map { ($0, $0.label) },
                          get: { settings.shelfTheme }, set: { settings.shelfTheme = $0 }, default: .off, isEnabled: designed),
            settingChoice("labelMark", "Label mark", LabelMarkStyle.allCases.map { ($0, $0.label) },
                          get: { settings.spineLabelMark }, set: { settings.spineLabelMark = $0 }, default: .badge, isEnabled: designed),
            settingToggle("ageSpines", "Age spines with release year", detail: "Older inserts yellow and fade; their cases pick up fine scuffs.",
                          get: { settings.ageSpinesWithYear }, set: { settings.ageSpinesWithYear = $0 }, default: true, isEnabled: designed),
            NerdKnob(id: "genreGroups", isChanged: { false }, reset: {},
                     view: AnyView(NerdButtonRow(label: "Genre groups", detail: "Which genres share a title face.", button: "Customize…",
                                                 isEnabled: designed, action: openGenreGroups))),
        ]
    }

    // MARK: Playlists, visualizer

    private var playlistSpacing: NerdKnob { slider(\.playlistRowSpacing, "Row spacing", 0...16, step: 1, unit: "pt") }

    private var visualizerOpensIn: NerdKnob {
        NerdKnob(id: "visualizerMode", isChanged: { false }, reset: {},
                 view: AnyView(NerdMenuRow(label: "Opens in", detail: "The Visualizer remembers the last mode you used; this sets it.",
                                           selection: Binding(get: { settings.visualizerMode }, set: { settings.visualizerMode = $0 }),
                                           options: VisualizerMode.allCases.map { ($0, $0.dialLabel) })))
    }

    // MARK: Builders

    /// Roughly the built-in throw's shape, for its graph: a fast flight that
    /// stops dead.
    static let thrownShape = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.3, y: 0.6), endControlPoint: UnitPoint(x: 0.45, y: 1))

    private func curve(_ kp: ReferenceWritableKeyPath<UIStyle, MotionCurve>, _ label: String, standard name: String,
                       standardShape: UnitCurve, detail: String? = nil) -> NerdKnob {
        let d = UIStyle.pristine[keyPath: kp]
        let changed = { style[keyPath: kp] != d }
        return NerdKnob(id: String(describing: kp), isChanged: changed, reset: { style[keyPath: kp] = d },
                        view: AnyView(NerdCurveRow(label: label, detail: detail,
                                                   selection: Binding(get: { style[keyPath: kp] }, set: { style[keyPath: kp] = $0 }),
                                                   standardName: name, standardShape: standardShape,
                                                   isChanged: changed(), reset: { style[keyPath: kp] = d })))
    }

    private func toggle(_ kp: ReferenceWritableKeyPath<UIStyle, Bool>, _ label: String, detail: String? = nil) -> NerdKnob {
        settingToggle(String(describing: kp), label, detail: detail, get: { style[keyPath: kp] }, set: { style[keyPath: kp] = $0 },
                      default: UIStyle.pristine[keyPath: kp])
    }

    private func slider(_ kp: ReferenceWritableKeyPath<UIStyle, Double>, _ label: String, _ range: ClosedRange<Double>,
                        step: Double, unit: String, detail: String? = nil) -> NerdKnob {
        let d = UIStyle.pristine[keyPath: kp]
        let changed = { abs(style[keyPath: kp] - d) > 0.0001 }
        return NerdKnob(id: String(describing: kp), isChanged: changed, reset: { style[keyPath: kp] = d },
                        view: AnyView(NerdSliderRow(label: label, detail: detail,
                                                    value: Binding(get: { style[keyPath: kp] }, set: { style[keyPath: kp] = $0 }),
                                                    range: range, step: step, unit: unit,
                                                    isChanged: changed(), reset: { style[keyPath: kp] = d })))
    }

    private func choice<V: Hashable>(_ kp: ReferenceWritableKeyPath<UIStyle, V>, _ label: String, _ options: [(V, String)],
                                     detail: String? = nil) -> NerdKnob {
        settingChoice(String(describing: kp), label, options, get: { style[keyPath: kp] }, set: { style[keyPath: kp] = $0 },
                      default: UIStyle.pristine[keyPath: kp], detail: detail)
    }

    private func settingToggle(_ id: String, _ label: String, detail: String? = nil, get: @escaping @MainActor () -> Bool,
                               set: @escaping @MainActor (Bool) -> Void, default d: Bool, isEnabled: Bool = true) -> NerdKnob {
        NerdKnob(id: id, isChanged: { get() != d }, reset: { set(d) },
                 view: AnyView(NerdToggleRow(label: label, detail: detail, isOn: Binding(get: get, set: set),
                                             isChanged: get() != d, isEnabled: isEnabled, reset: { set(d) })))
    }

    private func settingChoice<V: Hashable>(_ id: String, _ label: String, _ options: [(V, String)], get: @escaping @MainActor () -> V,
                                            set: @escaping @MainActor (V) -> Void, default d: V, detail: String? = nil,
                                            isEnabled: Bool = true) -> NerdKnob {
        NerdKnob(id: id, isChanged: { get() != d }, reset: { set(d) },
                 view: AnyView(NerdChoiceRow(label: label, detail: detail, selection: Binding(get: get, set: set),
                                             options: options, isChanged: get() != d, isEnabled: isEnabled, reset: { set(d) })))
    }
}

// MARK: - Rows

/// A knob's label, its reset dot (shown once it's been changed), an optional
/// value on the right and an optional line of explanation.
private struct NerdRowLabel: View {
    let label: String
    var value: String? = nil
    let isChanged: Bool
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if isChanged {
                Button(action: reset) {
                    Circle().fill(NerdPreview.select).frame(width: 7, height: 7)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset to the default")
                .accessibilityLabel("Reset \(label)")
                .transition(.opacity)
            }
            Spacer(minLength: 6)
            if let value {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isChanged)
    }
}

private struct NerdDetail: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row's padding and hover tint.
private struct NerdRow<Content: View>: View {
    var isEnabled = true
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.textPrimary.opacity(isHovering ? 0.04 : 0)))
            .onHover { isHovering = $0 }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct NerdToggleRow: View {
    let label: String
    let detail: String?
    @Binding var isOn: Bool
    let isChanged: Bool
    var isEnabled = true
    let reset: () -> Void

    var body: some View {
        NerdRow(isEnabled: isEnabled) {
            HStack(alignment: .center) {
                NerdRowLabel(label: label, isChanged: isChanged, reset: reset)
                Toggle(label, isOn: $isOn)
                    .toggleStyle(FLSwitchStyle())
                    .labelsHidden()
            }
            NerdDetail(text: detail)
        }
    }
}

private struct NerdSliderRow: View {
    let label: String
    let detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let isChanged: Bool
    let reset: () -> Void

    private var formatted: String {
        switch unit {
        case "×": return String(format: "%.2f×", value)
        case "%": return "\(Int((value * 100).rounded()))%"
        case "s": return String(format: "%.2g s", value)
        default: return "\(Int(value.rounded())) \(unit)"
        }
    }

    var body: some View {
        NerdRow {
            NerdRowLabel(label: label, value: formatted, isChanged: isChanged, reset: reset)
            Slider(value: $value, in: range, step: step)
                .tint(Theme.textPrimary)
                .controlSize(.small)
                .accessibilityValue(formatted)
            NerdDetail(text: detail)
        }
    }
}

private struct NerdChoiceRow<V: Hashable>: View {
    let label: String
    let detail: String?
    @Binding var selection: V
    let options: [(V, String)]
    let isChanged: Bool
    var isEnabled = true
    let reset: () -> Void

    var body: some View {
        NerdRow(isEnabled: isEnabled) {
            NerdRowLabel(label: label, isChanged: isChanged, reset: reset)
            FLPillToggle(selection: $selection, segments: options.map { .text($0.0, $0.1) })
            NerdDetail(text: detail)
        }
    }
}

private struct NerdMenuRow<V: Hashable>: View {
    let label: String
    let detail: String?
    @Binding var selection: V
    let options: [(V, String)]

    var body: some View {
        NerdRow {
            HStack {
                NerdRowLabel(label: label, isChanged: false, reset: {})
                Picker(label, selection: $selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            NerdDetail(text: detail)
        }
    }
}

/// A motion curve: the named curves in a menu, and a little graph of the
/// one picked (time across, progress up).
private struct NerdCurveRow: View {
    let label: String
    let detail: String?
    @Binding var selection: MotionCurve
    let standardName: String
    let standardShape: UnitCurve
    let isChanged: Bool
    let reset: () -> Void

    var body: some View {
        NerdRow {
            HStack(spacing: 10) {
                NerdRowLabel(label: label, isChanged: isChanged, reset: reset)
                CurveGraph(curve: selection.unitCurve(standard: standardShape))
                    .frame(width: 44, height: 28)
                    .accessibilityHidden(true)
                Picker(label, selection: $selection) {
                    ForEach(MotionCurve.allCases) { Text($0.label(standard: standardName)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            NerdDetail(text: detail)
        }
    }
}

private struct CurveGraph: View {
    let curve: UnitCurve

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for step in 0...32 {
                let t = Double(step) / 32
                let point = CGPoint(x: t * size.width, y: size.height - curve.value(at: t) * size.height)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var frame = Path()
            frame.move(to: CGPoint(x: 0, y: 0)); frame.addLine(to: CGPoint(x: 0, y: size.height)); frame.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(frame, with: .color(Theme.textTertiary.opacity(0.5)), lineWidth: 1)
            context.stroke(path, with: .color(Theme.textPrimary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .animation(.easeOut(duration: 0.2), value: curve.value(at: 0.5))
    }
}

private struct NerdButtonRow: View {
    let label: String
    let detail: String?
    let button: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        NerdRow(isEnabled: isEnabled) {
            HStack {
                NerdRowLabel(label: label, isChanged: false, reset: {})
                Button(button, action: action).buttonStyle(PillButtonStyle())
            }
            NerdDetail(text: detail)
        }
    }
}

/// The accent colour: the system colour picker, and the hex code to type or
/// paste. Picking either sets the accent to Custom.
private struct NerdColorRow: View {
    let isChanged: Bool
    let reset: () -> Void

    @State private var text = ""
    @FocusState private var isEditing: Bool

    private var style: UIStyle { .shared }

    var body: some View {
        NerdRow {
            NerdRowLabel(label: "Custom colour", isChanged: isChanged, reset: reset)
            HStack(spacing: 8) {
                ColorPicker("Custom colour", selection: Binding(
                    get: { UIStyle.color(hex: style.accentHex) ?? .blue },
                    set: { color in
                        style.accentHex = UIStyle.hex(of: NSColor(color))
                        style.accentMode = .custom
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                Text("#")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                TextField("4AA3FF", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 76)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isValid ? (isEditing ? NerdPreview.select : Theme.divider) : Theme.qualityLow, lineWidth: isEditing || !isValid ? 1.5 : 1))
                    .focused($isEditing)
                    .accessibilityLabel("Accent hex code")
                    .onChange(of: text) { _, new in
                        let digits = String(new.uppercased().filter(\.isHexDigit).prefix(6))
                        if digits != new { text = digits; return }
                        if UIStyle.nsColor(hex: digits) != nil, digits.count == 6 || digits.count == 3 {
                            style.accentHex = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
                            style.accentMode = .custom
                        }
                    }
                Spacer()
            }
            NerdDetail(text: "Pick or paste a hex code; Accent switches to Custom.")
        }
        .onAppear { text = style.accentHex }
        .onChange(of: style.accentHex) { _, hex in if !isEditing { text = hex } }
    }

    private var isValid: Bool { text.count == 6 || text.count == 3 || text.isEmpty }
}

/// Home's sections: drag to reorder, the eye to hide. Rests while Home
/// arranges itself.
private struct NerdSectionOrder: View {
    let isChanged: Bool
    let reset: () -> Void

    @Environment(Settings.self) private var settings
    @State private var dragging: HomeSection?

    private var order: [HomeSection] {
        var order = settings.homeSectionOrder.filter { HomeSection.allCases.contains($0) }
        for (index, section) in HomeSection.allCases.enumerated() where !order.contains(section) {
            order.insert(section, at: min(index, order.count))
        }
        return order
    }

    var body: some View {
        let auto = settings.homeArrangesAutomatically
        NerdRow {
            NerdRowLabel(label: "Order & visibility", value: auto ? "Automatic" : "Yours", isChanged: isChanged, reset: reset)
            VStack(spacing: 2) {
                ForEach(order) { section in
                    let hidden = settings.homeHiddenSections.contains(section)
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(section.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(hidden ? Theme.textTertiary : Theme.textPrimary)
                        Spacer()
                        Button {
                            if hidden { settings.homeHiddenSections.remove(section) } else { settings.homeHiddenSections.insert(section) }
                        } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(hidden ? "Show on Home" : "Hide from Home")
                        .accessibilityLabel(hidden ? "Show \(section.title)" : "Hide \(section.title)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Theme.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .opacity(dragging == section ? 0.4 : 1)
                    .draggable(section.rawValue) { Text(section.title).padding(6) }
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let moved = HomeSection(rawValue: raw), moved != section else { return false }
                        var next = order.filter { $0 != moved }
                        next.insert(moved, at: next.firstIndex(of: section) ?? next.endIndex)
                        settings.homeSectionOrder = next
                        return true
                    }
                }
            }
            .disabled(auto)
            .opacity(auto ? 0.45 : 1)
        }
    }
}

/// The loading animation: Random (a new one each launch) or one of them,
/// each running small; click to pick.
private struct NerdLoaderPicker: View {
    let isChanged: Bool
    let reset: () -> Void

    private var style: UIStyle { .shared }

    var body: some View {
        NerdRow {
            NerdRowLabel(label: "Loading animation", isChanged: isChanged, reset: reset)
            HStack(spacing: 6) {
                tile(nil, label: "Random") {
                    Image(systemName: "shuffle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                ForEach(LoadingAnimation.allCases) { animation in
                    tile(animation, label: animation.label) { BrandLoader(height: 16, style: animation) }
                }
            }
            NerdDetail(text: "On the loading screen, and wherever FLACtastic makes you wait. Random picks a new one each launch.")
        }
    }

    private func tile<Face: View>(_ animation: LoadingAnimation?, label: String, @ViewBuilder face: () -> Face) -> some View {
        let isOn = style.loadingAnimation == animation
        return Button { style.loadingAnimation = animation } label: {
            VStack(spacing: 6) {
                face()
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isOn ? Theme.textPrimary : Theme.divider, lineWidth: isOn ? 2 : 1))
                Text(label)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) loading animation")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Which way Collection › Albums opens, kept with the page's own toggle.
private struct NerdAlbumsOpenAs: View {
    @AppStorage("flactastic.collectionAlbumView") private var style: AlbumViewStyle = .shelf

    var body: some View {
        NerdRow {
            NerdRowLabel(label: "Albums open as", isChanged: style != .shelf, reset: { style = .shelf })
            FLPillToggle(selection: $style, segments: [.text(.shelf, "Rack"), .text(.grid, "Grid")])
            NerdDetail(text: "The same switch as at the top of Collection › Albums.")
        }
    }
}
