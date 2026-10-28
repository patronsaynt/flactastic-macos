import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edit Spine, from a spine's context menu: the spine large on the left,
/// changing as you go, with its art's position under it, and every rolled
/// choice on the right. Picking a value locks it for this album; the lock at
/// the end of a row gives it back to the roll, and the switch beside it hides
/// that part of the spine. Shuffle Unlocked rerolls only what's still open.
/// Artist and label logos are added here too, and apply to every album by
/// them.
///
/// Nothing is saved until Done; Cancel (or Esc) leaves the spine as it was.
struct EditSpineSheet: View {
    let album: Album
    let credit: String
    /// The album's artists, one name each.
    let artists: [String]

    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var overrides = SpineOverrides()
    @State private var shuffles = 0
    /// Logo files and their colouring, by lower-cased artist name, as edited.
    @State private var artistLogos: [String: String] = [:]
    @State private var artistTints: [String: LogoTint] = [:]
    @State private var labelLogo: String?
    @State private var labelTint: LogoTint = .auto
    @State private var labelBacking = true
    @State private var labelRotation: LogoRotation = .right
    /// Whether the cover has a colour strong enough to print an insert in.
    @State private var coverHasColour = true
    /// Logo files added in this session, deleted again if it's cancelled.
    @State private var imported: [String] = []
    /// Up to four colours sampled from the cover, as "#rrggbb".
    @State private var coverColors: [String] = []
    /// The art's position, kept apart from the rest so dragging it redraws
    /// only the preview.
    @State private var art = ArtPosition()
    /// The cover, decoded once at the preview's size and slid behind it.
    @State private var cover: NSImage?
    @State private var hasSeeded = false

    private static let previewScale: CGFloat = 1.3

    private var names: [String] { artists.isEmpty ? [credit] : artists }
    private var labelKey: String? { album.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var options: SpineDesign.Options {
        var o = settings.spineOptions
        for name in names {
            let key = name.lowercased()
            o.artistLogos[key] = artistLogos[key]
            o.artistLogoTints[key] = artistTints[key]
        }
        if let labelKey {
            o.labelLogos[labelKey] = labelLogo
            o.labelLogoTints[labelKey] = labelTint
            o.labelLogoBackings[labelKey] = labelBacking
            o.labelLogoRotations[labelKey] = labelRotation
        }
        return o
    }

    private func roll(_ overrides: SpineOverrides) -> SpineDesign {
        SpineDesign.roll(for: album, credit: credit, shuffles: shuffles, options: options, overrides: overrides, artists: artists)
    }

    var body: some View {
        // Rolled once per redraw: the spine as it stands, and as it would
        // be with nothing hidden (to know which parts it has at all).
        let current = roll(overrides)
        var unhidden = overrides
        unhidden.hidden = nil
        let full = roll(unhidden)
        return FLSheet(title: "Edit Spine", width: 800, height: 790, alwaysScrolls: true) {
            HStack(alignment: .top, spacing: 32) {
                SpinePreviewPanel(
                    album: album, credit: credit, byline: names.joined(separator: " × "), design: current, art: art, cover: cover,
                    clearCase: settings.clearCaseLook, blurArt: settings.blurSpineArt, scale: Self.previewScale
                )
                controls(current, full: full)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 20)
        } footer: {
            footer
        }
        .onAppear(perform: seed)
        .task { await loadCoverColors() }
        .task { await loadCover() }
    }

    // MARK: - Controls

    private func controls(_ d: SpineDesign, full: SpineDesign) -> some View {
        let insertNote = hidden(.insert) ? "The insert is hidden." : nil
        return VStack(alignment: .leading, spacing: 0) {
            row("Strip", locked: overrides.isLong != nil, unlock: { overrides.isLong = nil }, lock: { overrides.isLong = d.isLong },
                note: insertNote, shows: .insert) {
                choice("Short Band", selected: !d.isLong, locked: overrides.isLong != nil) { overrides.isLong = false }
                choice("Long Insert", selected: d.isLong, locked: overrides.isLong != nil) {
                    // A long insert has no free end for the artist; the
                    // latest pick wins, so an artist-on-the-art lock lets go.
                    overrides.isLong = true
                    if overrides.artistOnArt == true { overrides.artistOnArt = nil }
                }
            }
            row("Placement", locked: overrides.position != nil, unlock: { overrides.position = nil }, lock: { overrides.position = d.position }) {
                ForEach(SpineDesign.Position.allCases, id: \.self) { p in
                    choice(Self.name(p), selected: d.position == p, locked: overrides.position != nil) { overrides.position = p }
                }
            }
            row("Colour", locked: overrides.fill != nil, unlock: { overrides.fill = nil }, lock: { overrides.fill = Self.choice(for: d.fill) },
                note: insertNote) {
                swatch(.paper, label: "White paper", color: Color(nsColor: NSColor(srgbRed: 0.949, green: 0.937, blue: 0.906, alpha: 1)), design: d)
                swatch(.black, label: "Black", color: Color(white: 0.07), design: d)
                swatch(.art, label: coverHasColour ? "Cover colour: follows the cover" : "This cover is nearly grey, so it has no colour to print",
                       color: coverColors.first.flatMap(RackSpine.color(hex:)).map(Color.init(nsColor:)),
                       design: d, marksCover: true)
                    .disabled(!coverHasColour)
                    .opacity(coverHasColour ? 1 : 0.35)
                // Label House Style rolls the label's own colour; it can be
                // kept like any other.
                if case .house(let hue) = d.fill {
                    let hex = Self.hex(RackSpine.houseColor(hue))
                    swatch(.custom(hex: hex), label: "\(album.label ?? "Label") house colour", color: Color(nsColor: RackSpine.houseColor(hue)), design: d)
                }
                ForEach(coverColors, id: \.self) { hex in
                    swatch(.custom(hex: hex), label: "From the cover", color: RackSpine.color(hex: hex).map(Color.init(nsColor:)), design: d)
                }
            }
            row("Edge", locked: overrides.edge != nil, unlock: { overrides.edge = nil }, lock: { overrides.edge = d.edge },
                note: insertNote) {
                ForEach(SpineDesign.Edge.allCases, id: \.self) { e in
                    choice(e.rawValue.capitalized, selected: d.edge == e, locked: overrides.edge != nil) { overrides.edge = e }
                }
            }
            titleRow
            row("Title Face", locked: overrides.font != nil, unlock: { overrides.font = nil },
                lock: { overrides.font = d.font.map { .face($0) } ?? .system },
                note: hidden(.title) ? "The title is hidden." : nil, shows: .title) {
                faceMenu(d)
            }
            row("Lettering", locked: overrides.lettering != nil, unlock: { overrides.lettering = nil }, lock: { overrides.lettering = d.lettering }) {
                choice("As Tagged", selected: d.lettering == .tagged, locked: overrides.lettering != nil) { overrides.lettering = .tagged }
                choice("CAPS", selected: d.lettering == .caps, locked: overrides.lettering != nil) { overrides.lettering = .caps }
                choice("lower", selected: d.lettering == .lower, locked: overrides.lettering != nil) { overrides.lettering = .lower }
                choice("A.C.R.", selected: d.lettering == .acronym, locked: overrides.lettering != nil) { overrides.lettering = .acronym }
                    .help("The title as its initials")
                    .accessibilityLabel("Acronym")
            }
            row("Separator", locked: overrides.separator != nil, unlock: { overrides.separator = nil }, lock: { overrides.separator = d.separator },
                note: d.isLong || d.artistOnArt || hidden(.title) || hidden(.artist)
                    ? "Shows only on a short band with the title and the artist on the card." : nil) {
                ForEach(SpineDesign.Separator.allCases, id: \.self) { s in
                    choice(Self.name(s), selected: d.separator == s, locked: overrides.separator != nil) { overrides.separator = s }
                }
            }
            row("Artist", locked: overrides.artistOnArt != nil, unlock: { overrides.artistOnArt = nil }, lock: { overrides.artistOnArt = d.artistOnArt },
                note: hidden(.artist) ? "The artist is hidden." : nil, shows: .artist) {
                choice("On the Card", selected: !d.artistOnArt, locked: overrides.artistOnArt != nil) { overrides.artistOnArt = false }
                choice("On the Art", selected: d.artistOnArt, locked: overrides.artistOnArt != nil) {
                    overrides.artistOnArt = true
                    if overrides.isLong == true { overrides.isLong = nil }
                }
            }
            // Offered by what the album has, not by what's showing, so a
            // hidden mark can be switched back on.
            if let mark = full.mark {
                row("Label Mark", locked: overrides.markEnd != nil, unlock: { overrides.markEnd = nil }, lock: { overrides.markEnd = mark.end },
                    note: hidden(.labelMark) ? "The label mark is hidden." : nil, shows: .labelMark) {
                    choice("Top", selected: mark.end == .top, locked: overrides.markEnd != nil) { overrides.markEnd = .top }
                    choice("Foot", selected: mark.end == .bottom, locked: overrides.markEnd != nil) { overrides.markEnd = .bottom }
                }
            }
            if full.discCount > 1 {
                switchRow("Disc Count", detail: "\(full.discCount) CD on the insert", element: .discCount)
            }
            if full.age > 0 {
                switchRow("Wear", detail: album.year.map { "Aged paper and a scuffed case, from \($0)" } ?? "Aged paper and a scuffed case",
                          element: .wear)
            }

            logos
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The spine's title text, for a title whose tags don't print well (odd
    /// characters, a long subtitle). Empty prints the album's own.
    private var titleRow: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                SheetLabel(text: "Title")
                    .frame(width: 92, alignment: .leading)
                TextField(album.name, text: Binding(
                    get: { overrides.title ?? "" },
                    set: { overrides.title = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ))
                .textFieldStyle(QuietFieldStyle(font: .system(size: 13, weight: .medium)))
                .accessibilityLabel("Spine title")
                .help("Your own text for the title on this spine. Leave it empty for the album's title.")
                if overrides.title != nil {
                    Button("Use Album Title") { overrides.title = nil }
                        .buttonStyle(QuietTextButtonStyle())
                }
                // In line with the rows that end in a switch and a lock.
                Color.clear.frame(width: 40 + 12 + 30, height: 24)
            }
            .padding(.vertical, 8)
            Rectangle().fill(Theme.divider).frame(height: 0.5)
        }
    }

    private func hidden(_ element: SpineElement) -> Bool { overrides.hiddenElements.contains(element) }

    private func showing(_ element: SpineElement) -> Binding<Bool> {
        Binding(
            get: { !hidden(element) },
            set: { on in
                var set = overrides.hiddenElements
                if on { set.remove(element) } else { set.insert(element) }
                overrides.hidden = set.isEmpty ? nil : set
            }
        )
    }

    /// One attribute: its name, its choices, a switch to hide that part of
    /// the spine (when it's a part, `shows`), and its lock. With a `note`, the
    /// choices can't show on this spine as it stands; they rest, and the
    /// note says why.
    private func row<Content: View>(
        _ title: String, locked: Bool, unlock: @escaping () -> Void, lock: @escaping () -> Void,
        note: String? = nil, shows element: SpineElement? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                SheetLabel(text: title)
                    .frame(width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        content()
                    }
                    .disabled(note != nil)
                    .opacity(note == nil ? 1 : 0.4)
                    if let note {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                partSwitch(element, title: title)
                LockButton(isLocked: locked, attribute: title) { locked ? unlock() : lock() }
            }
            .padding(.vertical, 8)
            Rectangle().fill(Theme.divider).frame(height: 0.5)
        }
    }

    /// A part with nothing to choose, only whether it shows.
    private func switchRow(_ title: String, detail: String, element: SpineElement) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                SheetLabel(text: title)
                    .frame(width: 92, alignment: .leading)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(hidden(element) ? Theme.textTertiary : Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                partSwitch(element, title: title)
                // Keeps the switches in line with the rows that end in a lock.
                Color.clear.frame(width: 30, height: 30)
            }
            .padding(.vertical, 10)
            Rectangle().fill(Theme.divider).frame(height: 0.5)
        }
    }

    /// The show/hide switch, or the room for one so the locks line up.
    @ViewBuilder
    private func partSwitch(_ element: SpineElement?, title: String) -> some View {
        if let element {
            Toggle("", isOn: showing(element))
                .toggleStyle(FLSwitchStyle())
                .help(hidden(element) ? "Show the \(title.lowercased()) on this spine" : "Hide the \(title.lowercased()) on this spine")
                .accessibilityLabel("Show \(title)")
        } else {
            Color.clear.frame(width: 40, height: 24)
        }
    }

    private func choice(_ title: String, selected: Bool, locked: Bool, action: @escaping () -> Void) -> some View {
        SpineChoicePill(title: title, state: selected ? (locked ? .locked : .rolled) : .off, action: action)
    }

    private func swatch(_ value: SpineOverrides.FillChoice, label: String, color: Color?, design: SpineDesign, marksCover: Bool = false) -> some View {
        let selected = Self.choice(for: design.fill) == value
        return SpineSwatch(
            color: color, label: label, marksCover: marksCover,
            state: selected ? (overrides.fill != nil ? .locked : .rolled) : .off
        ) { overrides.fill = value }
    }

    /// The title face: the faces of the album's genre group first, then the
    /// rest by group, then the app's own. Opens the app's own menu, shown
    /// with the face's name set in the face itself.
    private func faceMenu(_ d: SpineDesign) -> some View {
        let tier = settings.genreGroups.tier(for: ([album.genre] + album.secondaryGenres.map(Optional.some)).compactMap { $0 })
        let locked = overrides.font != nil
        return Button {
            FLContextMenuWindow.present(items: faceItems(current: d.font, tier: tier), at: NSEvent.mouseLocation)
        } label: {
            HStack(spacing: 8) {
                Text(album.name)
                    .font(d.font.map { .custom($0.postScriptName, size: 15 * $0.scale) } ?? .system(size: 14, weight: .heavy))
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text(d.font?.displayName ?? "SF Pro")
                    .font(.system(size: 11.5))
                    .foregroundStyle(locked ? Theme.background.opacity(0.7) : Theme.textTertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(locked ? Theme.background.opacity(0.7) : Theme.textTertiary)
            }
            .foregroundStyle(locked ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(locked ? Theme.textPrimary : .clear))
            .overlay(Capsule().inset(by: 0.5).stroke(Theme.textPrimary.opacity(locked ? 0 : 0.45), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Choose the title's face")
        .accessibilityLabel("Title face, \(d.font?.displayName ?? "SF Pro")")
    }

    private func faceItems(current: SpineFont?, tier: GenreTier?) -> [FLContextMenuItem] {
        func item(_ face: SpineFont) -> FLContextMenuItem {
            .button(face.displayName, systemImage: face == current ? "checkmark" : nil) { overrides.font = .face(face) }
        }
        var items: [FLContextMenuItem] = []
        if let tier {
            items.append(.label("\(tier.name): this album's group"))
            items += tier.fonts.map(item)
            items.append(.divider)
        }
        items += GenreTier.allCases.filter { $0 != tier }.map { .submenu($0.name, items: $0.fonts.map(item)) }
        items.append(.divider)
        items.append(.button("App Font (SF Pro)", systemImage: current == nil ? "checkmark" : nil) { overrides.font = .system })
        return items
    }

    // MARK: - Logos

    private var logos: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetLabel(text: "Logos")
            ForEach(names, id: \.self) { name in
                let key = name.lowercased()
                LogoWell(
                    title: name,
                    caption: "Replaces \(name)'s name on every spine they're on.",
                    file: artistLogos[key],
                    tint: Binding(get: { artistTints[key] ?? .auto }, set: { artistTints[key] = $0 }),
                    choose: { chooseLogo { artistLogos[key] = $0 } },
                    remove: { artistLogos[key] = nil }
                )
            }
            if let label = album.label {
                LogoWell(
                    title: label,
                    caption: "Replaces the initials in the label mark on every \(label) spine.",
                    file: labelLogo,
                    tint: $labelTint,
                    backing: $labelBacking,
                    rotation: $labelRotation,
                    choose: { chooseLogo { labelLogo = $0 } },
                    remove: { labelLogo = nil }
                )
            }
        }
    }

    private func chooseLogo(_ set: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image"
        guard panel.runModal() == .OK, let url = panel.url, let name = SpineLogoStore.importImage(at: url) else { return }
        imported.append(name)
        set(name)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Reset") {
                overrides = SpineOverrides()
                shuffles = 0
                art.slice = nil
            }
            .buttonStyle(QuietTextButtonStyle())
            .disabled(overrides.isEmpty && shuffles == 0 && !art.isLocked)
            .help("Back to the spine this album's tags give it")
            Button("Shuffle Unlocked") { shuffles += 1 }
                .buttonStyle(SheetPillStyle())
                .disabled(overrides.lockedCount == 9 && art.isLocked)
            Button("Cancel") { cancel() }
                .buttonStyle(SheetPillStyle())
                .keyboardShortcut(.cancelAction)
            Button("Done") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var status: String {
        var parts: [String] = []
        let locked = overrides.lockedCount + (art.isLocked ? 1 : 0)
        if locked > 0 { parts.append("\(locked) locked") }
        if !overrides.hiddenElements.isEmpty { parts.append("\(overrides.hiddenElements.count) hidden") }
        if shuffles > 0 { parts.append("shuffled \(shuffles)×") }
        return parts.isEmpty ? "Rolled from the album's tags" : parts.joined(separator: " · ")
    }

    // MARK: - State

    private func seed() {
        guard !hasSeeded else { return }
        hasSeeded = true
        var saved = settings.spineOverrides[album.id] ?? SpineOverrides()
        art.slice = saved.slice
        saved.slice = nil
        overrides = saved
        shuffles = settings.spineShuffles[album.id] ?? 0
        for name in names {
            let key = name.lowercased()
            artistLogos[key] = settings.artistLogos[key]
            artistTints[key] = settings.artistLogoTints[key]
        }
        labelLogo = labelKey.flatMap { settings.labelLogos[$0] }
        labelTint = labelKey.flatMap { settings.labelLogoTints[$0] } ?? .auto
        labelBacking = labelKey.flatMap { settings.labelLogoBackings[$0] } ?? true
        labelRotation = labelKey.flatMap { settings.labelLogoRotations[$0] } ?? .right
    }

    private func loadCoverColors() async {
        guard let palette = await CoverPalette.load(for: album.artwork) else {
            coverHasColour = false
            return
        }
        // The same test the spine uses before printing an insert in it.
        coverHasColour = palette.swatches.first.map { $0.saturation * $0.brightness >= 0.22 } ?? false
        coverColors = palette.swatches.prefix(4).map { s in
            Self.hex(NSColor(hue: s.hue, saturation: min(s.saturation, 0.9), brightness: min(max(s.brightness, 0.3), 0.95), alpha: 1))
        }
    }

    /// Decodes the cover once, off the main thread, at the preview's height.
    private func loadCover() async {
        guard let data = album.artwork else { return }
        let pixels = Int(384 * Self.previewScale * displayScale)
        let image = await Task.detached(priority: .userInitiated) {
            PrerenderedImage.nsImage(PrerenderedImage.downsampled(data, maxPixel: pixels))
        }.value
        cover = image
    }

    private func save() {
        var saved = overrides
        saved.slice = art.slice
        settings.spineOverrides[album.id] = saved.isEmpty ? nil : saved
        settings.spineShuffles[album.id] = shuffles > 0 ? shuffles : nil
        var replaced: [String] = []
        for name in names {
            let key = name.lowercased()
            let old = settings.artistLogos[key]
            let new = artistLogos[key]
            settings.artistLogos[key] = new
            settings.artistLogoTints[key] = new == nil || (artistTints[key] ?? .auto) == .auto ? nil : artistTints[key]
            if let old, old != new { replaced.append(old) }
        }
        if let labelKey {
            let old = settings.labelLogos[labelKey]
            settings.labelLogos[labelKey] = labelLogo
            settings.labelLogoTints[labelKey] = labelLogo == nil || labelTint == .auto ? nil : labelTint
            // Only what differs from the defaults (with backing, facing Right).
            settings.labelLogoBackings[labelKey] = labelLogo == nil || labelBacking ? nil : false
            settings.labelLogoRotations[labelKey] = labelLogo == nil || labelRotation == .right ? nil : labelRotation
            if let old, old != labelLogo { replaced.append(old) }
        }
        // Files no artist or label uses any more, including ones added here
        // and then swapped for another before Done.
        let inUse = Set(settings.artistLogos.values).union(settings.labelLogos.values)
        for name in Set(replaced + imported) where !inUse.contains(name) {
            SpineLogoStore.remove(name)
        }
        dismiss()
    }

    private func cancel() {
        let inUse = Set(settings.artistLogos.values).union(settings.labelLogos.values)
        for name in imported where !inUse.contains(name) {
            SpineLogoStore.remove(name)
        }
        dismiss()
    }

    // MARK: - Names

    private static func name(_ p: SpineDesign.Position) -> String {
        switch p {
        case .top: return "Upper"
        case .center: return "Centre"
        case .bottom: return "Lower"
        }
    }

    private static func name(_ s: SpineDesign.Separator) -> String {
        switch s {
        case .none: return "None"
        case .dot: return "•"
        case .slash: return "/"
        case .rule: return "Rule"
        }
    }

    private static func choice(for fill: SpineDesign.Fill) -> SpineOverrides.FillChoice? {
        switch fill {
        case .paper: return .paper
        case .black: return .black
        case .art: return .art
        case .custom(let hex): return .custom(hex: hex)
        case .house(let hue): return .custom(hex: hex(RackSpine.houseColor(hue)))
        }
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - Preview

/// Where the spine's art is cut across the cover, while editing. Its own
/// object so a drag redraws the preview alone; the rest of the sheet only
/// reads `isLocked`, which changes once per lock or unlock, not per step.
@MainActor
@Observable
final class ArtPosition {
    /// Set when the person moved or shuffled it; nil leaves it to the roll.
    var slice: Double? {
        didSet {
            if (slice != nil) != isLocked { isLocked = slice != nil }
        }
    }
    private(set) var isLocked = false
}

/// The spine large, with the art's position under it: a slider to move the
/// cut across the cover, a shuffle, and a lock to give it back to the roll.
private struct SpinePreviewPanel: View {
    let album: Album
    let credit: String
    /// The artists as the spine sets them apart.
    let byline: String
    let design: SpineDesign
    let art: ArtPosition
    let cover: NSImage?
    let clearCase: Bool
    let blurArt: Bool
    let scale: CGFloat

    var body: some View {
        var shown = design
        if let slice = art.slice { shown.slice = slice }
        let rolled = design.slice
        return VStack(alignment: .leading, spacing: 14) {
            RackSpine(
                album: album, credit: credit, width: 30, height: 384, isHovered: false,
                design: shown, clearCase: clearCase, blurArt: blurArt, fullCover: cover
            )
            .equatable()
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 30 * scale, height: 384 * scale, alignment: .topLeading)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
            .accessibilityLabel("Spine preview")

            VStack(alignment: .leading, spacing: 6) {
                SheetLabel(text: "Art")
                HStack(spacing: 4) {
                    Slider(
                        value: Binding(get: { art.slice ?? rolled }, set: { art.slice = $0 }),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .tint(Theme.textPrimary)
                    .accessibilityLabel("Art position")
                    .help("Slide to move which part of the cover shows on the spine")
                    Button {
                        art.slice = Double.random(in: 0...1)
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Shuffle the art's position")
                    .accessibilityLabel("Shuffle the art's position")
                    LockButton(isLocked: art.isLocked, attribute: "Art") {
                        art.slice = art.isLocked ? nil : rolled
                    }
                }
                .disabled(album.artwork == nil)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(byline)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(width: 170, alignment: .leading)
    }
}

// MARK: - Parts

/// How a choice reads: the roll's current pick (outlined), a pick the person
/// locked (solid), or another option (quiet).
private enum ChoiceState { case off, rolled, locked }

/// A choice in Edit Spine, in the edit sheets' pill shape.
private struct SpineChoicePill: View {
    let title: String
    let state: ChoiceState
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(state == .locked ? Theme.background : state == .rolled ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(state == .locked ? Theme.textPrimary : Theme.textPrimary.opacity(isHovering ? 0.06 : 0)))
                .overlay(Capsule().inset(by: 0.5).stroke(Theme.textPrimary.opacity(state == .rolled ? 0.45 : state == .off ? 0.14 : 0), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: state)
        .accessibilityAddTraits(state == .off ? [] : [.isSelected])
        .accessibilityValue(state == .locked ? "Locked" : state == .rolled ? "Rolled" : "")
    }
}

/// A strip colour. The cover-colour swatch carries a small photo glyph: it
/// follows the cover rather than being fixed.
private struct SpineSwatch: View {
    let color: Color?
    let label: String
    var marksCover = false
    let state: ChoiceState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color ?? Theme.textPrimary.opacity(0.12))
                if marksCover {
                    Image(systemName: "photo")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                }
                Circle().strokeBorder(Theme.textPrimary.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: 24, height: 24)
            .padding(3)
            .overlay(
                Circle().strokeBorder(Theme.textPrimary.opacity(state == .locked ? 1 : state == .rolled ? 0.45 : 0), lineWidth: 2)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(state == .off ? [] : [.isSelected])
    }
}

/// The lock at the end of a row: closed when the person picked the value,
/// open when it's left to the roll.
private struct LockButton: View {
    let isLocked: Bool
    let attribute: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isLocked ? Theme.textPrimary : (isHovering ? Theme.textSecondary : Theme.textTertiary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isLocked ? "Unlock \(attribute): let it roll again" : "Lock \(attribute) as it is")
        .accessibilityLabel(isLocked ? "Unlock \(attribute)" : "Lock \(attribute)")
    }
}

/// A logo slot: the image (or the name it stands in for) on a quiet well,
/// Add/Replace and Remove, and once there's a logo, how it's coloured.
private struct LogoWell: View {
    let title: String
    let caption: String
    let file: String?
    @Binding var tint: LogoTint
    /// For a label logo: whether its badge or band shows behind it, and
    /// which way it faces. Nil for artists' logos.
    var backing: Binding<Bool>? = nil
    var rotation: Binding<LogoRotation>? = nil
    let choose: () -> Void
    let remove: () -> Void

    var body: some View {
        let logo = file.flatMap(SpineLogoStore.logo)
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
                if let logo {
                    Image(nsImage: logo.image)
                        .renderingMode(logo.isCutOut && tint != .original ? .template : .original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
            }
            .frame(width: 132, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if logo != nil, let backing, let rotation {
                    HStack(spacing: 10) {
                        Toggle("", isOn: backing)
                            .toggleStyle(FLSwitchStyle())
                            .accessibilityLabel("Backing")
                        Text("Backing")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .help("The badge or band behind the logo. Off, the logo sits on the art on its own.")
                    }
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(LogoRotation.allCases) { option in
                            SpineChoicePill(title: option.label, state: option == rotation.wrappedValue ? .locked : .off) {
                                rotation.wrappedValue = option
                            }
                            .help("Which way the logo faces on the spine")
                        }
                    }
                }
                if let logo {
                    if logo.isCutOut {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(LogoTint.allCases) { option in
                                SpineChoicePill(title: option.label, state: option == tint ? .locked : .off) { tint = option }
                                    .help(Self.help(option))
                            }
                        }
                    } else {
                        Text("This logo has no transparent background, so it shows in its own colours. Use a PNG with a transparent background to colour it.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 2) {
                    Button(file == nil ? "Add Logo…" : "Replace…", action: choose)
                        .buttonStyle(QuietTextButtonStyle())
                    if file != nil {
                        Button("Remove", action: remove)
                            .buttonStyle(QuietTextButtonStyle())
                    }
                }
                .padding(.leading, -10)
            }
            Spacer(minLength: 0)
        }
    }

    private static func help(_ tint: LogoTint) -> String {
        switch tint {
        case .auto: return "Each album picks white, black or its cover's colour, whichever reads on its spine"
        case .white: return "Always white"
        case .black: return "Always black"
        case .cover: return "Each album's cover colour"
        case .original: return "The logo's own colours"
        }
    }
}
