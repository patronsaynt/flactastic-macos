import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edit Spine, from a spine's context menu: a workshop with the case on a
/// stage, turned by dragging, and the spine large beside it. Click a part of
/// the spine (the insert, title, artist, label mark or art) to open its
/// panel; the tab row over the panels does the same.
///
/// Every setting shows the spine's value as it stands and picking one sets
/// it. Surprise Me rolls the whole spine again, or just one part of it, and
/// Undo walks back through any of it. Reset to Tags returns to the spine the
/// album's tags give it. Artist and label logos are added here too, and
/// apply to every album by them.
///
/// Nothing is saved until Done; Cancel (or Esc, or the close button) leaves
/// the spine as it was, asking first when something changed.
struct EditSpineSheet: View {
    let album: Album
    let credit: String
    /// The album's artists, one name each.
    let artists: [String]

    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// Everything the sheet edits, kept whole so Undo can step back through it.
    struct Draft: Equatable {
        var overrides = SpineOverrides()
        var shuffles = 0
        /// Logo files and their colouring, by lower-cased artist name.
        var artistLogos: [String: String] = [:]
        var artistTints: [String: LogoTint] = [:]
        var labelLogo: String?
        var labelTint: LogoTint = .auto
        var labelBacking = true
        var labelRotation: LogoRotation = .right
    }

    @State private var draft = Draft()
    /// The draft as the sheet opened, to tell whether anything changed.
    @State private var opened = Draft()
    @State private var undoStack: [Draft] = []
    @State private var redoStack: [Draft] = []
    @State private var part: SpinePart = .insert
    @State private var confirmingDiscard = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// The font being hovered in the face list, and the art being dragged:
    /// read only by the stage, so they redraw the previews alone.
    @State private var live = SpineEditLive()
    /// Whether the cover has a colour strong enough to print an insert in.
    @State private var coverHasColour = true
    /// Up to four colours sampled from the cover, as "#rrggbb".
    @State private var coverColors: [String] = []
    /// The cover, decoded once at the preview's size.
    @State private var cover: NSImage?
    /// Logo files added in this session, deleted again if it's cancelled.
    @State private var imported: [String] = []
    @State private var hasSeeded = false
    @State private var faceFilter = ""
    @FocusState private var titleFocused: Bool
    /// The draft as typing in the title began, kept for Undo on the first
    /// change: one undo step per stretch of typing, not per key.
    @State private var titleStart: Draft?
    /// Whether this album has a spine scan the shelf shows in place of the
    /// designed spine, with Use Spine Scans on.
    @State private var hasScan = false
    /// Fitted to the window it's shown over, which may be smaller than the
    /// workshop's full size.
    @State private var size = Self.fittedSize()

    private var names: [String] { artists.isEmpty ? [credit] : artists }
    private var labelKey: String? { album.label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var options: SpineDesign.Options {
        var o = settings.spineOptions
        for name in names {
            let key = name.lowercased()
            o.artistLogos[key] = draft.artistLogos[key]
            o.artistLogoTints[key] = draft.artistTints[key]
        }
        if let labelKey {
            o.labelLogos[labelKey] = draft.labelLogo
            o.labelLogoTints[labelKey] = draft.labelTint
            o.labelLogoBackings[labelKey] = draft.labelBacking
            o.labelLogoRotations[labelKey] = draft.labelRotation
        }
        return o
    }

    private func roll(_ overrides: SpineOverrides, shuffles: Int? = nil) -> SpineDesign {
        SpineDesign.roll(for: album, credit: credit, shuffles: shuffles ?? draft.shuffles, options: options, overrides: overrides, artists: artists)
    }

    var body: some View {
        // Rolled once per redraw: the spine as it stands, and as it would be
        // with nothing hidden (to know which parts it has at all).
        let options = options
        let current = SpineDesign.roll(for: album, credit: credit, shuffles: draft.shuffles, options: options, overrides: draft.overrides, artists: artists)
        var unhidden = draft.overrides
        unhidden.hidden = nil
        let full = SpineDesign.roll(for: album, credit: credit, shuffles: draft.shuffles, options: options, overrides: unhidden, artists: artists)
        let parts = availableParts(full)
        return VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                SpineStage(
                    album: album, credit: credit, byline: names.joined(separator: " × "), design: current, overrides: draft.overrides,
                    options: options, shuffles: draft.shuffles, artists: artists, cover: cover, live: live,
                    clearCase: settings.clearCaseLook, blurArt: settings.blurSpineArt,
                    selected: parts.contains(part) ? part : .insert, parts: parts, toast: toast,
                    select: { if parts.contains($0) { part = $0 } },
                    canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty, canReset: draft.overrides != SpineOverrides() || draft.shuffles != 0,
                    surprise: surprise, undo: undo, redo: redo, reset: resetToTags
                )
                .padding(.leading, 20)
                .padding(.bottom, 14)
                inspector(current, full: full, parts: parts)
                    .frame(width: 452)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.surface)
        .onAppear(perform: seed)
        .task { await loadCoverColors() }
        .task { await loadCover() }
        .task { await findScan() }
        .onChange(of: titleFocused) { _, focused in
            titleStart = focused ? draft : nil
        }
    }

    /// The workshop's size, shrunk to fit a smaller window.
    private static func fittedSize() -> CGSize {
        let window = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentLayoutRect.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: min(1160, max(960, window.width - 40)), height: min(780, max(600, window.height - 40)))
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            SheetLabel(text: "Edit Spine")
            Spacer()
            SheetCloseButton(label: "Close without saving", handlesEscape: false) { requestCancel() }
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if confirmingDiscard {
                Text("Discard your changes to this spine?")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Keep Editing") { confirmingDiscard = false }
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Discard") { cancel() }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Text(status)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { requestCancel() }
                    .buttonStyle(SheetPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Done") { save() }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.18), value: confirmingDiscard)
    }

    private var isDirty: Bool { draft != opened }

    private var status: String {
        guard isDirty else { return "Rolled from the album's tags" }
        let changed = SpinePart.allCases.filter { edited($0) }.map(\.title)
        return changed.isEmpty ? "Changed" : "Changed: " + changed.joined(separator: " · ")
    }

    // MARK: - Inspector

    private func availableParts(_ full: SpineDesign) -> [SpinePart] {
        var parts: [SpinePart] = [.insert, .title, .artist]
        if album.label != nil { parts.append(.label) }
        parts.append(.art)
        if full.discCount > 1 || full.age > 0 { parts.append(.finish) }
        return parts
    }

    /// Whether a part differs from how the sheet opened, for the tab's dot.
    private func edited(_ p: SpinePart) -> Bool {
        let a = draft.overrides, b = opened.overrides
        let rolled = draft.shuffles != opened.shuffles
        switch p {
        case .insert: return rolled || a.isLong != b.isLong || a.position != b.position || a.fill != b.fill || a.edge != b.edge
            || a.hiddenElements.contains(.insert) != b.hiddenElements.contains(.insert)
        case .title: return a.font != b.font || a.lettering != b.lettering || a.title != b.title
            || a.hiddenElements.contains(.title) != b.hiddenElements.contains(.title)
        case .artist: return a.artistOnArt != b.artistOnArt || a.separator != b.separator
            || a.hiddenElements.contains(.artist) != b.hiddenElements.contains(.artist)
            || draft.artistLogos != opened.artistLogos || draft.artistTints != opened.artistTints
        case .label: return a.markEnd != b.markEnd || a.hiddenElements.contains(.labelMark) != b.hiddenElements.contains(.labelMark)
            || draft.labelLogo != opened.labelLogo || draft.labelTint != opened.labelTint
            || draft.labelBacking != opened.labelBacking || draft.labelRotation != opened.labelRotation
        case .art: return a.slice != b.slice
        case .finish: return a.hiddenElements.subtracting([.insert, .title, .artist, .labelMark]) != b.hiddenElements.subtracting([.insert, .title, .artist, .labelMark])
        }
    }

    private func inspector(_ d: SpineDesign, full: SpineDesign, parts: [SpinePart]) -> some View {
        let shown = parts.contains(part) ? part : .insert
        return VStack(alignment: .leading, spacing: 0) {
            tabs(parts, selected: shown)
                .padding(.bottom, 16)
            Group {
                switch shown {
                case .title:
                    // The face list scrolls itself and takes the rest of the height.
                    titlePanel(d)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switch shown {
                            case .insert: insertPanel(d)
                            case .artist: artistPanel(d)
                            case .label: labelPanel(d, full: full)
                            case .art: artPanel(d)
                            case .finish: finishPanel(full)
                            case .title: EmptyView()
                            }
                        }
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .id(shown)
            .transition(.opacity.combined(with: .offset(x: 8)))
        }
        .padding(.leading, 24)
        .padding(.trailing, 28)
        .animation(.easeOut(duration: 0.2), value: shown)
    }

    private func tabs(_ parts: [SpinePart], selected: SpinePart) -> some View {
        HStack(spacing: 2) {
            ForEach(parts) { p in
                let off = p.element.map { draft.overrides.hiddenElements.contains($0) } ?? false
                Button { part = p } label: {
                    HStack(spacing: 5) {
                        Text(p.title)
                            .strikethrough(off)
                            .opacity(off ? 0.6 : 1)
                        if edited(p) {
                            Circle().frame(width: 5, height: 5).opacity(0.75)
                        }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected == p ? Theme.background : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Capsule().fill(selected == p ? Theme.textPrimary : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == p ? [.isSelected] : [])
                .help(p.help)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.textPrimary.opacity(0.07)))
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    /// A panel's title, what it's for, and the switch that shows or hides
    /// that part of the spine.
    private func panelHeader(_ title: String, subtitle: String, shows element: SpineElement? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let element {
                    Toggle(isOn: showing(element)) {
                        Text("Show")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(FLSwitchStyle())
                    .help(hidden(element) ? "Show the \(title.lowercased()) on this spine" : "Hide the \(title.lowercased()) on this spine")
                    .accessibilityLabel("Show \(title)")
                }
            }
            .padding(.bottom, 14)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// A labelled group of controls, with the value it's set to on the right.
    private func section<Content: View>(_ title: String, value: String? = nil, gated: Bool = false, note: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SheetLabel(text: title)
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            content()
                .disabled(gated)
                .opacity(gated ? 0.38 : 1)
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
    }

    // MARK: Insert

    private func insertPanel(_ d: SpineDesign) -> some View {
        let off = hidden(.insert)
        let note = off ? "The insert is hidden, so the type prints straight on the art." : nil
        return VStack(alignment: .leading, spacing: 0) {
            panelHeader("Insert", subtitle: off ? "Hidden. The type prints straight on the art." : "The paper strip the type is printed on.", shows: .insert)
            if hasScan {
                Hint(text: "This album has a spine scan, and Use Spine Scans is on, so the shelf shows the scan. Your design is kept for when it's off.")
                    .padding(.top, 16)
            }
            section("Strip", value: d.isLong ? "Long insert" : "Short band", gated: off) {
                HStack(spacing: 8) {
                    SpineTile(title: "Short band", detail: "Hugs the text", isOn: !d.isLong) {
                        MiniSpine(isLong: false, position: .center)
                    } action: { set { $0.isLong = false } }
                    SpineTile(title: "Long insert", detail: "More paper around it", isOn: d.isLong) {
                        MiniSpine(isLong: true, position: .center)
                    } action: { chooseLongInsert() }
                }
            }
            section("Placement", value: Self.name(d.position)) {
                HStack(spacing: 8) {
                    ForEach(SpineDesign.Position.allCases, id: \.self) { p in
                        SpineTile(title: Self.name(p), isOn: d.position == p) {
                            MiniSpine(isLong: d.isLong, position: p)
                        } action: { set { $0.position = p } }
                    }
                }
            }
            section("Colour", value: fillName(d.fill), gated: off) {
                swatches(d)
            }
            section("Edge", value: d.edge.rawValue.capitalized, gated: off, note: note) {
                HStack(spacing: 8) {
                    ForEach(SpineDesign.Edge.allCases, id: \.self) { e in
                        SpineTile(title: e.rawValue.capitalized, isOn: d.edge == e) {
                            EdgeGlyph(edge: e)
                        } action: { set { $0.edge = e } }
                    }
                }
            }
        }
    }

    private func swatches(_ d: SpineDesign) -> some View {
        let picked = Self.choice(for: d.fill)
        return VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 10, lineSpacing: 10) {
                SpineSwatch(color: Color(nsColor: NSColor(srgbRed: 0.949, green: 0.937, blue: 0.906, alpha: 1)), label: "White paper",
                            isOn: picked == .paper) { set { $0.fill = .paper } }
                SpineSwatch(color: Color(white: 0.07), label: "Black", isOn: picked == .black) { set { $0.fill = .black } }
                SpineSwatch(color: coverColors.first.flatMap(RackSpine.color(hex:)).map(Color.init(nsColor:)),
                            label: coverHasColour ? "Cover colour: follows the cover" : "This cover is nearly grey, so it has no colour to print",
                            marksCover: true, isOn: picked == .art) { set { $0.fill = .art } }
                    .disabled(!coverHasColour)
                    .opacity(coverHasColour ? 1 : 0.35)
                Rectangle().fill(Theme.divider).frame(width: 1, height: 26).padding(.top, 6)
                // Label House Style rolls the label's own colour; it can be
                // kept like any other.
                if case .house(let hue) = d.fill {
                    let hex = Self.hex(RackSpine.houseColor(hue))
                    SpineSwatch(color: Color(nsColor: RackSpine.houseColor(hue)), label: "\(album.label ?? "Label") house colour",
                                isOn: picked == .custom(hex: hex)) { set { $0.fill = .custom(hex: hex) } }
                }
                ForEach(coverColors, id: \.self) { hex in
                    SpineSwatch(color: RackSpine.color(hex: hex).map(Color.init(nsColor:)), label: "From the cover",
                                isOn: picked == .custom(hex: hex)) { set { $0.fill = .custom(hex: hex) } }
                }
            }
            if !coverHasColour {
                Text("This cover is nearly grey, so it has no colour to print an insert in.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func fillName(_ fill: SpineDesign.Fill) -> String {
        switch fill {
        case .paper: return "White paper"
        case .black: return "Black"
        case .art: return "Cover colour"
        case .house: return "\(album.label ?? "Label") house colour"
        case .custom: return "From the cover"
        }
    }

    // MARK: Title

    private func titlePanel(_ d: SpineDesign) -> some View {
        let off = hidden(.title)
        return VStack(alignment: .leading, spacing: 0) {
            panelHeader("Title", subtitle: off ? "Hidden on this spine." : "What the spine prints, and in what face.", shows: .title)
            section("Text", gated: off) {
                HStack(spacing: 8) {
                    TextField(album.name, text: Binding(
                        get: { draft.overrides.title ?? "" },
                        set: { text in
                            let title = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                            guard title != draft.overrides.title else { return }
                            if let start = titleStart {
                                if undoStack.last != start { undoStack.append(start) }
                                redoStack.removeAll()
                                titleStart = nil
                            }
                            draft.overrides.title = title
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($titleFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.textPrimary.opacity(titleFocused ? 0.08 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.textPrimary.opacity(titleFocused ? 0.3 : 0), lineWidth: 1))
                    .accessibilityLabel("Spine title")
                    .help("Your own text for the title on this spine. Leave it empty for the album's title.")
                    if draft.overrides.title != nil {
                        Button("Use Album Title") { set { $0.title = nil } }
                            .buttonStyle(QuietTextButtonStyle())
                    }
                }
            }
            section("Lettering") {
                SpineSegments(selection: d.lettering, options: [
                    (.tagged, "Aa", "As tagged"), (.caps, "AA", "Caps"), (.lower, "aa", "Lower"), (.acronym, "A.C.R.", "Initials"),
                ]) { l in set { $0.lettering = l } }
            }
            faceList(d)
                .disabled(off)
                .opacity(off ? 0.38 : 1)
        }
    }

    /// Every face, set in this album's own title: this album's genre group
    /// first, then the rest by group, then the app's own. Hovering one shows
    /// it on the spine and case; clicking sets it.
    private func faceList(_ d: SpineDesign) -> some View {
        let tier = settings.genreGroups.tier(for: ([album.genre] + album.secondaryGenres.map(Optional.some)).compactMap { $0 })
        let query = faceFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let groups = ([tier].compactMap { $0 } + GenreTier.allCases.filter { $0 != tier }).compactMap { t -> (GenreTier, [SpineFont])? in
            let faces = t.fonts.filter { query.isEmpty || $0.displayName.lowercased().contains(query) }
            return faces.isEmpty ? nil : (t, faces)
        }
        let sample = Self.cased(String(d.title.prefix(28)), d.lettering)
        let current: SpineOverrides.FontChoice = d.font.map { .face($0) } ?? .system
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SheetLabel(text: "Face")
                Text(d.font?.displayName ?? "App Font (SF Pro)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                TextField("Filter faces", text: $faceFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12)
                    .frame(width: 150, height: 28)
                    .background(Capsule().fill(Theme.textPrimary.opacity(0.06)))
                    .accessibilityLabel("Filter faces")
            }
            .padding(.top, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if query.isEmpty {
                            FaceRow(sample: sample, name: "App Font (SF Pro)", face: nil, isOn: current == .system, live: live,
                                    choice: .system) { set { $0.font = .system } }
                        }
                        ForEach(groups, id: \.0) { group in
                            Section {
                                ForEach(group.1, id: \.self) { face in
                                    FaceRow(sample: sample, name: face.displayName, face: face, isOn: current == .face(face), live: live,
                                            choice: .face(face)) { set { $0.font = .face(face) } }
                                    .id(face)
                                }
                            } header: {
                                HStack {
                                    Text(group.0.name.uppercased())
                                        .font(.system(size: 11, weight: .bold))
                                        .kerning(1.1)
                                        .foregroundStyle(Theme.textTertiary)
                                    Spacer()
                                    if group.0 == tier {
                                        Text("This album's group")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 9)
                                .padding(.bottom, 6)
                                .background(Theme.surfaceElevated.opacity(0.97))
                            }
                        }
                        if groups.isEmpty {
                            Text("No face named “\(faceFilter)”.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(28)
                        }
                    }
                    .padding(4)
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.04)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onAppear { if let f = d.font { proxy.scrollTo(f, anchor: .center) } }
            }
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Artist

    private func artistPanel(_ d: SpineDesign) -> some View {
        let off = hidden(.artist)
        let free: SpineDesign.Position = d.position == .top ? .bottom : d.position == .bottom ? .top : d.artistEnd
        let separatorShows = !d.isLong && !d.artistOnArt && !hidden(.title) && !off
        return VStack(alignment: .leading, spacing: 0) {
            panelHeader("Artist", subtitle: off ? "Hidden on this spine." : names.joined(separator: " × "), shows: .artist)
            section("Where It Goes", value: d.artistOnArt ? "On the art" : "On the card", gated: off) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SpineTile(title: "On the card", detail: "Printed on the insert", isOn: !d.artistOnArt) {
                            MiniSpine(isLong: d.isLong, position: .center)
                        } action: { set { $0.artistOnArt = false } }
                        SpineTile(title: "On the art", detail: "At the free end", isOn: d.artistOnArt) {
                            MiniSpine(isLong: false, position: d.position, artistEnd: free)
                        } action: { chooseArtistOnArt() }
                    }
                    if d.isLong {
                        Hint(text: "A long insert fills the spine, so there's no free end for the artist. Choosing On the art switches to a short band.")
                    }
                }
            }
            section("Separator", value: Self.name(d.separator), gated: !separatorShows,
                    note: separatorShows ? nil : "Shows only on a short band with the title and the artist both on the card.") {
                SpineSegments(selection: d.separator, options: SpineDesign.Separator.allCases.map { ($0, Self.glyph($0), Self.name($0)) }) { s in
                    set { $0.separator = s }
                }
            }
            ForEach(names, id: \.self) { name in
                let key = name.lowercased()
                LogoWell(
                    heading: names.count > 1 ? "Logo · \(name)" : "Logo",
                    title: name,
                    scope: "Every album by \(name)",
                    caption: "Replaces \(name)'s name on every spine they're on.",
                    file: draft.artistLogos[key],
                    tint: Binding(get: { draft.artistTints[key] ?? .auto }, set: { t in set(logo: true) { $0.artistTints[key] = t } }),
                    choose: { chooseLogo { name in set(logo: true) { $0.artistLogos[key] = name } } },
                    drop: { url in importLogo(url) { name in set(logo: true) { $0.artistLogos[key] = name } } },
                    remove: { set(logo: true) { $0.artistLogos[key] = nil } }
                )
                .padding(.top, 20)
            }
        }
    }

    // MARK: Label

    private func labelPanel(_ d: SpineDesign, full: SpineDesign) -> some View {
        let off = hidden(.labelMark)
        let label = album.label ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            if let mark = full.mark {
                panelHeader("Label Mark", subtitle: off ? "Hidden on this spine." : label, shows: .labelMark)
                section("Which End", value: mark.end == .top ? "Top" : "Foot", gated: off) {
                    HStack(spacing: 8) {
                        SpineTile(title: "Top", isOn: mark.end == .top) {
                            MiniSpine(isLong: false, position: .center, markEnd: .top)
                        } action: { set { $0.markEnd = .top } }
                        SpineTile(title: "Foot", isOn: mark.end == .bottom) {
                            MiniSpine(isLong: false, position: .center, markEnd: .bottom)
                        } action: { set { $0.markEnd = .bottom } }
                    }
                }
            } else {
                panelHeader("Label", subtitle: label)
                Hint(text: "Label marks are off in Settings, so this spine doesn't show one. A logo added here is kept for when they're on.")
                    .padding(.top, 16)
            }
            LogoWell(
                heading: "Logo",
                title: label,
                scope: "Every \(label) spine",
                caption: "Replaces the initials in the label mark.",
                file: draft.labelLogo,
                tint: Binding(get: { draft.labelTint }, set: { t in set(logo: true) { $0.labelTint = t } }),
                backing: Binding(get: { draft.labelBacking }, set: { b in set(logo: true) { $0.labelBacking = b } }),
                rotation: Binding(get: { draft.labelRotation }, set: { r in set(logo: true) { $0.labelRotation = r } }),
                choose: { chooseLogo { name in set(logo: true) { $0.labelLogo = name } } },
                drop: { url in importLogo(url) { name in set(logo: true) { $0.labelLogo = name } } },
                remove: { set(logo: true) { $0.labelLogo = nil } }
            )
            .padding(.top, 20)
            .disabled(off)
            .opacity(off ? 0.38 : 1)
        }
    }

    // MARK: Art

    private func artPanel(_ d: SpineDesign) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Art")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Which slice of the cover shows on the spine.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    set { $0.slice = Double.random(in: 0...1) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(SheetPillStyle())
                .controlSize(.small)
                .disabled(album.artwork == nil)
                .help("Shuffle the art's position")
            }
            .padding(.bottom, 14)
            Rectangle().fill(Theme.divider).frame(height: 1)
            section("Cover", note: album.artwork == nil ? "This album has no cover art." : "Drag the frame, or use the arrow keys. The spine and case follow.") {
                CoverSlicePicker(cover: cover, slice: d.slice, live: live,
                                 begin: { record() },
                                 commit: { value in draft.overrides.slice = value; live.slice = nil },
                                 step: { delta in set { $0.slice = min(1, max(0, d.slice + delta)) } })
                    .disabled(album.artwork == nil)
            }
        }
    }

    // MARK: Finish

    private func finishPanel(_ full: SpineDesign) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Finish", subtitle: "Details the album's tags add to the spine.")
            if full.discCount > 1 {
                finishRow("Disc Count", detail: "\(full.discCount) CD on the insert", element: .discCount)
            }
            if full.age > 0 {
                finishRow("Wear", detail: album.year.map { "Aged paper and a scuffed case, from \($0)" } ?? "Aged paper and a scuffed case",
                          element: .wear)
            }
        }
    }

    private func finishRow(_ title: String, detail: String, element: SpineElement) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Toggle(isOn: showing(element)) {
                    Text("Show")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(FLSwitchStyle())
                .accessibilityLabel("Show \(title)")
            }
            .padding(.vertical, 16)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: - Editing

    /// Keeps the draft as it stands for Undo.
    private func record() {
        if undoStack.last != draft { undoStack.append(draft) }
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// One edit to the spine's overrides, undoable.
    private func set(_ change: (inout SpineOverrides) -> Void) {
        var next = draft.overrides
        change(&next)
        guard next != draft.overrides else { return }
        record()
        draft.overrides = next
    }

    /// One edit to the logos, undoable.
    private func set(logo: Bool, _ change: (inout Draft) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        record()
        draft = next
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = last
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = next
    }

    private func hidden(_ element: SpineElement) -> Bool { draft.overrides.hiddenElements.contains(element) }

    private func showing(_ element: SpineElement) -> Binding<Bool> {
        Binding(
            get: { !hidden(element) },
            set: { on in
                set { o in
                    var hidden = o.hiddenElements
                    if on { hidden.remove(element) } else { hidden.insert(element) }
                    o.hidden = hidden.isEmpty ? nil : hidden
                }
            }
        )
    }

    /// A long insert has no free end for the artist; the latest pick wins.
    private func chooseLongInsert() {
        let movesArtist = roll(draft.overrides).artistOnArt
        set { o in
            o.isLong = true
            if movesArtist { o.artistOnArt = false }
        }
        if movesArtist { show("The artist moved to the card: a long insert has no free end.") }
    }

    private func chooseArtistOnArt() {
        let shortens = roll(draft.overrides).isLong
        set { o in
            o.artistOnArt = true
            if shortens { o.isLong = false }
        }
        if shortens { show("Switched to a short band, so the artist has a free end.") }
    }

    /// Rolls again: the whole spine, or one part of it with the rest kept as
    /// it is. Hidden parts and your own title text are left alone.
    private func surprise(_ scope: SurpriseScope) {
        let d = roll(draft.overrides)
        var o = draft.overrides
        // Keep what's outside the scope by setting it to what it shows now,
        // then let the scope's own settings roll with the next shuffle.
        if scope != .everything {
            o.isLong = d.isLong; o.position = d.position; o.fill = Self.choice(for: d.fill); o.edge = d.edge
            o.font = d.font.map { .face($0) } ?? .system; o.lettering = d.lettering
            o.separator = d.separator; o.artistOnArt = d.artistOnArt
            o.markEnd = d.mark?.end ?? o.markEnd
            o.slice = d.slice
        }
        switch scope {
        case .everything:
            o.isLong = nil; o.position = nil; o.fill = nil; o.edge = nil; o.font = nil; o.lettering = nil
            o.separator = nil; o.artistOnArt = nil; o.markEnd = nil; o.slice = nil
        case .insert: o.isLong = nil; o.position = nil; o.fill = nil; o.edge = nil
        case .title: o.font = nil; o.lettering = nil
        case .artist: o.artistOnArt = nil; o.separator = nil
        case .art: o.slice = nil
        }
        // The two can't both be set; the artist's own end wins in the roll.
        if o.isLong == true && o.artistOnArt == true { o.artistOnArt = nil }
        record()
        draft.overrides = o
        draft.shuffles += 1
    }

    private func resetToTags() {
        guard draft.overrides != SpineOverrides() || draft.shuffles != 0 else { return }
        record()
        draft.overrides = SpineOverrides()
        draft.shuffles = 0
    }

    private func show(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Logos

    private func chooseLogo(_ set: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLogo(url, set)
    }

    private func importLogo(_ url: URL, _ set: (String) -> Void) {
        guard let name = SpineLogoStore.importImage(at: url) else { return }
        imported.append(name)
        set(name)
    }

    // MARK: - Saving

    private func requestCancel() {
        if confirmingDiscard {
            confirmingDiscard = false
        } else if isDirty {
            confirmingDiscard = true
        } else {
            cancel()
        }
    }

    private func seed() {
        guard !hasSeeded else { return }
        hasSeeded = true
        var d = Draft()
        d.overrides = settings.spineOverrides[album.id] ?? SpineOverrides()
        d.shuffles = settings.spineShuffles[album.id] ?? 0
        for name in names {
            let key = name.lowercased()
            d.artistLogos[key] = settings.artistLogos[key]
            d.artistTints[key] = settings.artistLogoTints[key]
        }
        d.labelLogo = labelKey.flatMap { settings.labelLogos[$0] }
        d.labelTint = labelKey.flatMap { settings.labelLogoTints[$0] } ?? .auto
        d.labelBacking = labelKey.flatMap { settings.labelLogoBackings[$0] } ?? true
        d.labelRotation = labelKey.flatMap { settings.labelLogoRotations[$0] } ?? .right
        draft = d
        opened = d
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

    private func findScan() async {
        guard settings.useSpineScans, let folder = album.tracks.first?.url.deletingLastPathComponent() else { return }
        hasScan = await Task.detached(priority: .utility) { SpineScanCache.scanFile(in: folder) != nil }.value
    }

    /// Decodes the cover once, off the main thread, at the preview's height.
    private func loadCover() async {
        guard let data = album.artwork else { return }
        let pixels = Int(384 * SpineStage.maxScale * displayScale)
        let image = await Task.detached(priority: .userInitiated) {
            PrerenderedImage.nsImage(PrerenderedImage.downsampled(data, maxPixel: pixels))
        }.value
        cover = image
    }

    private func save() {
        var saved = draft.overrides
        if let slice = live.slice { saved.slice = slice }
        settings.spineOverrides[album.id] = saved.isEmpty ? nil : saved
        settings.spineShuffles[album.id] = draft.shuffles > 0 ? draft.shuffles : nil
        var replaced: [String] = []
        for name in names {
            let key = name.lowercased()
            let old = settings.artistLogos[key]
            let new = draft.artistLogos[key]
            settings.artistLogos[key] = new
            settings.artistLogoTints[key] = new == nil || (draft.artistTints[key] ?? .auto) == .auto ? nil : draft.artistTints[key]
            if let old, old != new { replaced.append(old) }
        }
        if let labelKey {
            let old = settings.labelLogos[labelKey]
            let logo = draft.labelLogo
            settings.labelLogos[labelKey] = logo
            settings.labelLogoTints[labelKey] = logo == nil || draft.labelTint == .auto ? nil : draft.labelTint
            // Only what differs from the defaults (with backing, facing Right).
            settings.labelLogoBackings[labelKey] = logo == nil || draft.labelBacking ? nil : false
            settings.labelLogoRotations[labelKey] = logo == nil || draft.labelRotation == .right ? nil : draft.labelRotation
            if let old, old != logo { replaced.append(old) }
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

    static func name(_ p: SpineDesign.Position) -> String {
        switch p {
        case .top: return "Upper"
        case .center: return "Centre"
        case .bottom: return "Lower"
        }
    }

    private static func name(_ s: SpineDesign.Separator) -> String {
        switch s {
        case .none: return "None"
        case .dot: return "Dot"
        case .slash: return "Slash"
        case .rule: return "Rule"
        }
    }

    private static func glyph(_ s: SpineDesign.Separator) -> String {
        switch s {
        case .none: return "–"
        case .dot: return "•"
        case .slash: return "/"
        case .rule: return "|"
        }
    }

    private static func cased(_ text: String, _ lettering: SpineDesign.Lettering) -> String {
        switch lettering {
        case .caps: return text.uppercased()
        case .lower: return text.lowercased()
        case .tagged, .acronym: return text
        }
    }

    static func choice(for fill: SpineDesign.Fill) -> SpineOverrides.FillChoice {
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

// MARK: - Parts

/// The parts of a spine Edit Spine has a panel for.
enum SpinePart: String, CaseIterable, Identifiable {
    case insert, title, artist, label, art, finish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insert: return "Insert"
        case .title: return "Title"
        case .artist: return "Artist"
        case .label: return "Label"
        case .art: return "Art"
        case .finish: return "Finish"
        }
    }

    var help: String {
        switch self {
        case .insert: return "The paper strip: its length, place, colour and edge"
        case .title: return "The title's text, lettering and face"
        case .artist: return "Where the artist goes, and their logo"
        case .label: return "The record label's mark and logo"
        case .art: return "Which slice of the cover shows"
        case .finish: return "Disc count and wear"
        }
    }

    /// The part of the drawn spine it stands for; nil for the art (the whole
    /// spine) and Finish (whose disc count is placed by `marker`).
    var element: SpineElement? {
        switch self {
        case .insert: return .insert
        case .title: return .title
        case .artist: return .artist
        case .label: return .labelMark
        case .art, .finish: return nil
        }
    }

    /// The element whose place on the preview stands for this part.
    var marker: SpineElement? { self == .finish ? .discCount : element }

    init?(_ element: SpineElement) {
        switch element {
        case .insert: self = .insert
        case .title: self = .title
        case .artist: self = .artist
        case .labelMark: self = .label
        case .discCount, .wear: self = .finish
        }
    }
}

enum SurpriseScope: CaseIterable {
    case everything, insert, title, artist, art

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .insert: return "Just the Insert"
        case .title: return "Just the Title Face and Lettering"
        case .artist: return "Just the Artist's Place"
        case .art: return "Just the Art's Position"
        }
    }
}

/// What only the previews follow while it changes: a face hovered in the
/// list, and the art's position while its frame is dragged. Kept apart from
/// the sheet's state so a hover or a drag step redraws the stage alone.
@MainActor
@Observable
final class SpineEditLive {
    var font: SpineOverrides.FontChoice?
    var slice: Double?
}

// MARK: - Stage

/// The case on the left, turned by dragging, and the spine large on the
/// right, whose parts can be clicked; the toolbar along the foot.
private struct SpineStage: View {
    static let maxScale: CGFloat = 1.4

    let album: Album
    let credit: String
    let byline: String
    let design: SpineDesign
    let overrides: SpineOverrides
    let options: SpineDesign.Options
    let shuffles: Int
    let artists: [String]
    let cover: NSImage?
    let live: SpineEditLive
    let clearCase: Bool
    let blurArt: Bool
    let selected: SpinePart
    let parts: [SpinePart]
    let toast: String?
    let select: (SpinePart) -> Void
    let canUndo: Bool
    let canRedo: Bool
    let canReset: Bool
    let surprise: (SurpriseScope) -> Void
    let undo: () -> Void
    let redo: () -> Void
    let reset: () -> Void

    @State private var settle = false
    /// The stage's size, measured once layout is done. A GeometryReader
    /// here put the stage's contents (some shown only some of the time)
    /// inside the size AppKit asks the sheet for as it opens, which made
    /// SwiftUI's layout depend on itself.
    @State private var size = CGSize(width: 680, height: 600)

    /// The spine as previewed: with a hovered face, and the art where it's
    /// being dragged to.
    private var previewed: SpineDesign {
        var d = design
        if let font = live.font {
            var o = overrides
            o.font = font
            d = SpineDesign.roll(for: album, credit: credit, shuffles: shuffles, options: options, overrides: o, artists: artists)
        }
        if let slice = live.slice { d.slice = slice }
        return d
    }

    var body: some View {
        let shown = previewed
        let heroWidth: CGFloat = 250
        let scale = min(Self.maxScale, max(0.8, (size.height - 72) / 384))
        let caseSize = min(size.width - heroWidth - 80, size.height - 190)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(byline)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: max(0, size.width - heroWidth - 48), alignment: .leading)
            .padding(.leading, 24)
            .padding(.top, 20)

            TurningCase(album: album, credit: credit, design: casing(shown), size: max(120, caseSize), clearCase: clearCase, blurArt: blurArt)
                .frame(width: max(0, size.width - heroWidth), height: max(0, size.height - 70))
                .padding(.top, 34)

            SpineHero(album: album, credit: credit, design: shown, cover: cover, clearCase: clearCase, blurArt: blurArt,
                      scale: scale, selected: selected, parts: parts, select: select)
                .offset(y: settle ? -12 : 0)
                .frame(width: heroWidth, height: max(0, size.height - 64))
                .offset(x: size.width - heroWidth)

            toolbar
                .padding(.horizontal, 16)
                .frame(width: size.width, height: 64)
                .offset(y: size.height - 64)

            if let toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.textPrimary))
                    .frame(width: size.width)
                    .offset(y: size.height - 112)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    private var meta: String {
        var bits: [String] = []
        if let genre = album.genre { bits.append(genre) }
        if let label = album.label { bits.append(label) }
        if let year = album.year { bits.append(String(year)) }
        if design.discCount > 1 { bits.append("\(design.discCount) discs") }
        return bits.joined(separator: " · ")
    }

    /// The case spine cuts its own slice of art, which each step of a drag
    /// shouldn't redo; it follows the art once the drag ends.
    private func casing(_ d: SpineDesign) -> SpineDesign {
        var d = d
        if live.slice != nil { d.slice = design.slice }
        return d
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button {
                    surpriseNow(.everything)
                } label: {
                    Label("Surprise Me", systemImage: "dice")
                        .padding(.trailing, 2)
                }
                .buttonStyle(StagePillStyle(isPrimary: true, shape: .leading))
                .help("Roll the whole spine again")
                Button {
                    FLContextMenuWindow.present(items: SurpriseScope.allCases.enumerated().flatMap { i, scope -> [FLContextMenuItem] in
                        let item = FLContextMenuItem.button(scope.title) { surpriseNow(scope) }
                        return i == 1 ? [.divider, item] : [item]
                    }, at: NSEvent.mouseLocation)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(StagePillStyle(isPrimary: true, shape: .trailing))
                .help("Roll just one part again")
                .accessibilityLabel("Surprise me options")
            }
            StageIconButton(systemImage: "arrow.uturn.backward", label: "Undo", action: undo)
                .disabled(!canUndo)
                .keyboardShortcut("z", modifiers: .command)
            StageIconButton(systemImage: "arrow.uturn.forward", label: "Redo", action: redo)
                .disabled(!canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer()
            Button(action: reset) {
                Label("Reset to Tags", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(StagePillStyle())
            .disabled(!canReset)
            .help("Back to the spine this album's tags give it")
        }
    }

    private func surpriseNow(_ scope: SurpriseScope) {
        surprise(scope)
        settle = true
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) { settle = false }
    }
}

/// The case, turned by dragging it or with the slider, Spine and Front.
/// Its own view, so turning it redraws the case alone.
private struct TurningCase: View {
    let album: Album
    let credit: String
    let design: SpineDesign
    let size: CGFloat
    let clearCase: Bool
    let blurArt: Bool

    @State private var angle: Double = 42
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            RackBox(album: album, credit: credit, design: design, size: size, depth: size * 30 / 384,
                    clearCase: clearCase, blurArt: blurArt, angle: angle)
                .shadow(color: .black.opacity(0.4), radius: 22, y: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            let start = dragStart ?? angle
                            dragStart = start
                            angle = min(90, max(-20, start - Double(v.translation.width) * 0.4))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .help("Drag to turn the case")
                .accessibilityLabel("Case preview")
            HStack(spacing: 10) {
                Text("Turn the case")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Slider(value: $angle, in: -20...90)
                    .controlSize(.small)
                    .tint(Theme.textPrimary)
                    .frame(width: 150)
                    .accessibilityLabel("Turn the case")
                Button("Spine") { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)) { angle = 90 } }
                    .buttonStyle(StageChipStyle())
                Button("Front") { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)) { angle = 0 } }
                    .buttonStyle(StageChipStyle())
            }
            Spacer(minLength: 0)
        }
    }
}

/// The spine large, its parts outlined on hover and clickable; the part
/// being edited is ringed and named beside it.
private struct SpineHero: View {
    let album: Album
    let credit: String
    let design: SpineDesign
    let cover: NSImage?
    let clearCase: Bool
    let blurArt: Bool
    let scale: CGFloat
    let selected: SpinePart
    let parts: [SpinePart]
    let select: (SpinePart) -> Void

    @State private var hovered: SpinePart?
    /// Where each part of the spine is drawn, in the spine's own space,
    /// reported by the spine once it's laid out.
    @State private var frames: [SpineElement: [UUID: CGRect]] = [:]

    /// Each part's frames joined (an artist line with two names is one).
    private var rects: [SpineElement: CGRect] {
        frames.compactMapValues { byView in byView.isEmpty ? nil : byView.values.reduce(CGRect.null) { $0.union($1) } }
    }

    var body: some View {
        RackSpine(
            album: album, credit: credit, width: 30, height: 384, isHovered: false,
            design: design, clearCase: clearCase, blurArt: blurArt, fullCover: cover, reportsParts: true
        )
        .equatable()
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: 30 * scale, height: 384 * scale, alignment: .topLeading)
        .coordinateSpace(name: SpinePartReporting.space)
        .environment(\.spinePartReporter, SpinePartReporter { element, id, rect in
            if frames[element]?[id] != rect { frames[element, default: [:]][id] = rect }
        })
        .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
        .overlay(alignment: .topLeading) {
            let whole = CGRect(x: 0, y: 0, width: 30 * scale, height: 384 * scale)
            let rects = rects
            let spineWidth = whole.width
            ZStack(alignment: .topLeading) {
                    // The art: anywhere on the spine that isn't a part.
                    zone(.art, rect: whole)
                    ForEach(SpineElement.allCases.filter { rects[$0] != nil }) { element in
                        if let p = SpinePart(element), parts.contains(p), let r = rects[element] {
                            zone(p, rect: r.insetBy(dx: -2, dy: -2))
                        }
                    }
                    if let hovered, hovered != selected, let r = rect(hovered, rects, whole) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.textPrimary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: r.width + 6, height: r.height + 6)
                            .offset(x: r.minX - 3, y: r.minY - 3)
                            .allowsHitTesting(false)
                        // Hung off a point with no size, so the label
                        // never widens the overlay and shifts the outlines.
                        Color.clear.frame(width: 0, height: 0)
                            .overlay(alignment: .leading) { chip("\(hovered.title) · click to edit", filled: false).fixedSize() }
                            .offset(x: spineWidth + 14, y: r.midY)
                            .allowsHitTesting(false)
                    }
                    if let r = rect(selected, rects, whole) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.textPrimary, lineWidth: 2)
                            .frame(width: r.width + 8, height: r.height + 8)
                            .offset(x: r.minX - 4, y: r.minY - 4)
                            .allowsHitTesting(false)
                        Color.clear.frame(width: 0, height: 0)
                            .overlay(alignment: .trailing) { chip(selected == .label ? "Label mark" : selected.title, filled: true).fixedSize() }
                            .offset(x: -16, y: r.midY)
                            .allowsHitTesting(false)
                    }
            }
            .frame(width: whole.width, height: whole.height, alignment: .topLeading)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3), value: selected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spine preview")
        .accessibilityHint("The parts of the spine can be chosen with the tabs beside it")
    }

    /// Where a part sits on the spine: the art is the whole spine; a part
    /// that's hidden or not drawn has no place.
    private func rect(_ p: SpinePart, _ rects: [SpineElement: CGRect], _ whole: CGRect) -> CGRect? {
        if p == .art { return whole }
        guard let e = p.marker else { return nil }
        return rects[e]
    }

    private func zone(_ p: SpinePart, rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: max(rect.width, 6), height: max(rect.height, 6))
            .offset(x: rect.minX, y: rect.minY)
            .onHover { inside in
                if inside { hovered = p } else if hovered == p { hovered = nil }
            }
            .onTapGesture { select(p) }
    }

    private func chip(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(filled ? Theme.textPrimary : Theme.surfaceElevated))
    }
}

/// The cover with a frame the spine's width that slides across it: where
/// the spine's slice of art is cut.
private struct CoverSlicePicker: View {
    let cover: NSImage?
    let slice: Double
    let live: SpineEditLive
    let begin: () -> Void
    let commit: (Double) -> Void
    let step: (Double) -> Void

    @State private var dragging = false
    /// Its width, measured after layout (see SpineStage.size for why not a
    /// GeometryReader).
    @State private var w: CGFloat = 400
    @FocusState private var focused: Bool

    var body: some View {
        let fraction: CGFloat = 30 / 384
        let value = live.slice ?? slice
        let frameWidth = w * fraction
        return Color.clear
        .aspectRatio(1, contentMode: .fit)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w = $0 }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: w, height: w)
                        .clipped()
                } else {
                    Theme.textPrimary.opacity(0.08)
                }
                Path { p in
                    p.addRect(CGRect(x: 0, y: 0, width: w, height: w))
                    p.addRect(CGRect(x: (w - frameWidth) * value, y: 0, width: frameWidth, height: w))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(.white, lineWidth: 2)
                    .frame(width: frameWidth, height: w)
                    .overlay {
                        HStack {
                            Capsule().fill(.white.opacity(0.9)).frame(width: 3, height: 26).offset(x: -8)
                            Spacer()
                            Capsule().fill(.white.opacity(0.9)).frame(width: 3, height: 26).offset(x: 8)
                        }
                    }
                    .offset(x: (w - frameWidth) * value)
            }
            .frame(width: w, height: w)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.textPrimary.opacity(focused ? 0.6 : 0.14), lineWidth: focused ? 2 : 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; begin() }
                        let x = (v.location.x - frameWidth / 2) / max(1, w - frameWidth)
                        live.slice = min(1, max(0, Double(x)))
                    }
                    .onEnded { _ in
                        dragging = false
                        if let s = live.slice { commit(s) }
                    }
            )
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-0.02); return .handled }
        .onKeyPress(.rightArrow) { step(0.02); return .handled }
        .accessibilityElement()
        .accessibilityLabel("Art position")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 0.05 : -0.05)
        }
    }
}

// MARK: - Controls

/// A choice drawn as a small picture of what it does to the spine.
private struct SpineTile<Picture: View>: View {
    let title: String
    var detail: String?
    let isOn: Bool
    @ViewBuilder let picture: () -> Picture
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                picture()
                    .frame(height: 64)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn || isHovering ? Theme.textPrimary : Theme.textSecondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.textPrimary.opacity(isOn || isHovering ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(isOn ? 1 : 0), lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.background)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.textPrimary))
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A row of choices in one track, the chosen one solid.
private struct SpineSegments<Value: Hashable>: View {
    let selection: Value
    let options: [(Value, String, String)]
    let pick: (Value) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { value, glyph, label in
                let on = value == selection
                Button { pick(value) } label: {
                    VStack(spacing: 1) {
                        Text(glyph)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                        Text(label)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(on ? Theme.background : Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.textPrimary : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.06)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A strip colour. The cover-colour swatch carries a small photo glyph: it
/// follows the cover rather than being fixed.
private struct SpineSwatch: View {
    let color: Color?
    let label: String
    var marksCover = false
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color ?? Theme.textPrimary.opacity(0.12))
                if marksCover {
                    Image(systemName: "photo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                }
                Circle().strokeBorder(Theme.textPrimary.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: 34, height: 34)
            .padding(4)
            .overlay(Circle().strokeBorder(Theme.textPrimary.opacity(isOn ? 1 : 0), lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// One face in the list: this album's title set in it. Hovering it shows it
/// on the previews.
private struct FaceRow: View {
    let sample: String
    let name: String
    let face: SpineFont?
    let isOn: Bool
    let live: SpineEditLive
    let choice: SpineOverrides.FontChoice
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(sample)
                    .font(face.map { .custom($0.postScriptName, size: 18 * $0.scale) } ?? .system(size: 16, weight: .heavy))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: 34, alignment: .leading)
                    .clipped()
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11.5))
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(isOn ? Theme.background.opacity(0.75) : Theme.textTertiary)
            }
            .foregroundStyle(isOn ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isOn ? Theme.textPrimary : Theme.textPrimary.opacity(isHovering ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
            if inside { live.font = choice } else if live.font == choice { live.font = nil }
        }
        .onDisappear { if live.font == choice { live.font = nil } }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A small note in a quiet box.
private struct Hint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.06)))
    }
}

/// A logo slot: the image (or the name it stands in for) on a quiet well,
/// who it applies to, Add/Replace and Remove, and once there's a logo, how
/// it's coloured. A file can be dropped on the well too.
private struct LogoWell: View {
    let heading: String
    let title: String
    let scope: String
    let caption: String
    let file: String?
    @Binding var tint: LogoTint
    /// For a label logo: whether its badge or band shows behind it, and
    /// which way it faces. Nil for artists' logos.
    var backing: Binding<Bool>? = nil
    var rotation: Binding<LogoRotation>? = nil
    let choose: () -> Void
    let drop: (URL) -> Void
    let remove: () -> Void

    @State private var isTargeted = false

    var body: some View {
        let logo = file.flatMap(SpineLogoStore.logo)
        VStack(alignment: .leading, spacing: 10) {
            SheetLabel(text: heading)
            Label(scope, systemImage: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.textPrimary.opacity(0.07)))
                .help("Logos apply to every spine by this name, not just this album")
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.textPrimary.opacity(isTargeted ? 0.12 : 0.06))
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
                .frame(width: 124, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(isTargeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    drop(url)
                    return true
                } isTargeted: { isTargeted = $0 }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        Button(file == nil ? "Add Logo…" : "Replace…", action: choose)
                            .buttonStyle(QuietTextButtonStyle())
                        if file != nil {
                            Button("Remove", action: remove)
                                .buttonStyle(QuietTextButtonStyle())
                        }
                    }
                    .padding(.leading, -10)
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let logo {
                if logo.isCutOut {
                    SpineSegments(selection: tint, options: LogoTint.allCases.map { ($0, Self.glyph($0), $0.label) }) { tint = $0 }
                } else {
                    Text("This logo has no transparent background, so it shows in its own colours. Use a PNG with a transparent background to colour it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let backing, let rotation {
                    HStack {
                        Text("Badge or band behind it")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Toggle("", isOn: backing)
                            .toggleStyle(FLSwitchStyle())
                            .accessibilityLabel("Backing")
                            .help("The badge or band behind the logo. Off, the logo sits on the art on its own.")
                    }
                    .padding(.top, 4)
                    SpineSegments(selection: rotation.wrappedValue, options: LogoRotation.allCases.map { ($0, Self.glyph($0), $0.label) }) {
                        rotation.wrappedValue = $0
                    }
                    .help("Which way the logo faces on the spine")
                }
            }
        }
    }

    private static func glyph(_ tint: LogoTint) -> String {
        switch tint {
        case .auto: return "A"
        case .white: return "○"
        case .black: return "●"
        case .cover: return "◐"
        case .original: return "◇"
        }
    }

    private static func glyph(_ rotation: LogoRotation) -> String {
        switch rotation {
        case .left: return "↺"
        case .upright: return "↑"
        case .right: return "↻"
        }
    }
}

// MARK: - Pictures

/// A spine in miniature for the tiles: its art, the insert at its length and
/// place, and optionally the artist on the art or a label mark.
private struct MiniSpine: View {
    let isLong: Bool
    let position: SpineDesign.Position
    var artistEnd: SpineDesign.Position?
    var markEnd: SpineDesign.Position?

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 16, h: CGFloat = 60
            let x = (size.width - w) / 2, y = (size.height - h) / 2
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 2), with: .color(Theme.textPrimary.opacity(0.24)))
            let sh: CGFloat = isLong ? 34 : 17
            let sy: CGFloat = position == .top ? y + 6 : position == .bottom ? y + h - 6 - sh : y + (h - sh) / 2
            let strip = CGRect(x: x, y: sy, width: w, height: sh)
            ctx.fill(Path(strip), with: .color(Color(red: 0.94, green: 0.93, blue: 0.89)))
            ctx.stroke(Path(strip), with: .color(.black.opacity(0.4)), lineWidth: 0.6)
            var ink = Path()
            ink.move(to: CGPoint(x: x + w / 2, y: sy + 3))
            ink.addLine(to: CGPoint(x: x + w / 2, y: sy + sh - 3))
            ctx.stroke(ink, with: .color(Color(white: 0.12)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            if let artistEnd {
                var a = Path()
                let ay = artistEnd == .top ? y + 4 : y + h - 16
                a.move(to: CGPoint(x: x + w / 2, y: ay))
                a.addLine(to: CGPoint(x: x + w / 2, y: ay + 12))
                ctx.stroke(a, with: .color(Theme.textPrimary.opacity(0.85)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
            if let markEnd {
                let my = markEnd == .top ? y + 3 : y + h - 10
                ctx.fill(Path(ellipseIn: CGRect(x: x + w / 2 - 3.5, y: my, width: 7, height: 7)), with: .color(Theme.textPrimary))
            }
        }
        .frame(width: 40, height: 64)
        .accessibilityHidden(true)
    }
}

/// The end of an insert, cut straight, torn or ruled.
private struct EdgeGlyph: View {
    let edge: SpineDesign.Edge

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(x: 6, y: (size.height - 32) / 2, width: size.width - 14, height: 32)
            var paper = Path()
            if edge == .torn {
                paper.move(to: CGPoint(x: rect.minX, y: rect.minY))
                paper.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                let teeth = 8
                for i in 1...teeth {
                    let t = CGFloat(i) / CGFloat(teeth)
                    paper.addLine(to: CGPoint(x: rect.maxX - (i.isMultiple(of: 2) ? 0 : 3.5), y: rect.minY + rect.height * t))
                }
                paper.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                paper.closeSubpath()
            } else {
                paper = Path(rect)
            }
            ctx.fill(paper, with: .color(Color(red: 0.94, green: 0.93, blue: 0.89)))
            ctx.stroke(paper, with: .color(.black.opacity(0.4)), lineWidth: 0.6)
            var lines = Path()
            if edge == .ruled {
                lines.move(to: CGPoint(x: rect.minX, y: rect.minY + 3.5)); lines.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 3.5))
                lines.move(to: CGPoint(x: rect.minX, y: rect.maxY - 3.5)); lines.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3.5))
            }
            ctx.stroke(lines, with: .color(Color(white: 0.12).opacity(0.6)), lineWidth: 1)
            var ink = Path()
            ink.move(to: CGPoint(x: rect.minX + 8, y: rect.midY)); ink.addLine(to: CGPoint(x: rect.maxX - 12, y: rect.midY))
            ctx.stroke(ink, with: .color(Color(white: 0.12)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .frame(width: 60, height: 64)
        .accessibilityHidden(true)
    }
}

// MARK: - Stage buttons

private struct StagePillStyle: ButtonStyle {
    enum Shape { case whole, leading, trailing }
    var isPrimary = false
    var shape: Shape = .whole
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isPrimary ? Theme.background : Theme.textPrimary)
            .padding(.leading, shape == .trailing ? 11 : 16)
            .padding(.trailing, shape == .leading ? 12 : shape == .trailing ? 11 : 16)
            .frame(height: 36)
            .background(UnevenRoundedRectangle(
                topLeadingRadius: shape == .trailing ? 6 : 18, bottomLeadingRadius: shape == .trailing ? 6 : 18,
                bottomTrailingRadius: shape == .leading ? 6 : 18, topTrailingRadius: shape == .leading ? 6 : 18,
                style: .continuous
            ).fill(isPrimary ? Theme.textPrimary : Theme.textPrimary.opacity(0.08)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct StageChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Theme.textPrimary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Capsule())
    }
}

private struct StageIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering ? 0.09 : 0)))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
