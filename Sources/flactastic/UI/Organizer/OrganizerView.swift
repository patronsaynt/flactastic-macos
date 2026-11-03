import SwiftUI

/// The Organizer tab: reshape the library folder by a rule (folder levels and
/// a file name pattern), see the result live, then apply it.
///
/// Laid out as a builder and a preview. The builder scrolls on the left: the
/// whole rule as one large example path, then the folder levels, the file
/// name, the tags that can go in either, and two options. The preview fills
/// a panel on the right with the resulting tree, the move / in place /
/// conflict counts, and the Organize button. The preview re-plans
/// automatically (debounced) as the rule changes, and organizing is gated
/// behind a confirmation because it moves files in place.
struct OrganizerView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerState.self) private var player
    @State private var store = OrganizerProfilesStore()
    @State private var model = OrganizerModel()
    @State private var showApplyConfirm = false
    @State private var showRename = false
    @State private var renameDraft = ""
    /// Which template the tags insert into. Survives the field losing focus
    /// when a tag is clicked.
    @State private var activeTarget: TemplateTarget = .filename
    @FocusState private var focusedField: TemplateTarget?

    private enum TemplateTarget: Hashable {
        case filename
        case level(UUID)
    }

    private static let previewWidth: CGFloat = 460

    /// Stand-in used to render template examples before a library has been
    /// scanned, so the builder is never showing blank example lines.
    private static let sampleTrack = Track(
        url: URL(fileURLWithPath: "/Music/Sample Song.flac"),
        title: "Sample Song",
        artist: "SZA",
        albumArtist: "SZA",
        album: "Album Title",
        trackNumber: 1,
        fileFormat: .flac,
        genre: "Electronic",
        year: 2024
    )

    var body: some View {
        HStack(spacing: 0) {
            builderColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            previewColumn
                .frame(width: Self.previewWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay {
            if model.isApplying {
                applyOverlay
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.isApplying)
        .onChange(of: focusedField) { _, newValue in
            if let newValue { activeTarget = newValue }
        }
        .onChange(of: store.selected) { _, _ in refreshPreview() }
        .onChange(of: library.tracks.count) { _, _ in refreshPreview() }
        .onChange(of: library.rootURL) { _, _ in refreshPreview() }
        .task { refreshPreview() }
        .confirmationDialog(
            "Move \(model.moveCount) file\(model.moveCount == 1 ? "" : "s")?",
            isPresented: $showApplyConfirm,
            titleVisibility: .visible
        ) {
            Button("Move Files", role: .destructive) {
                Task {
                    await model.apply(library: library, player: player.engine, profile: store.selected)
                    refreshPreview()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: $showRename) {
            renameSheet
        }
    }

    private func refreshPreview() {
        model.schedulePreview(
            profile: store.selected,
            tracks: library.tracks,
            rootURL: library.rootURL
        )
    }

    private func mutateProfile(_ body: (inout OrganizerProfile) -> Void) {
        var profile = store.selected
        body(&profile)
        store.selected = profile
    }

    private var exampleTrack: Track {
        library.tracks.first ?? Self.sampleTrack
    }

    private func example(for template: String, fallback: String) -> String {
        OrganizerTemplate.render(
            template,
            for: exampleTrack,
            fallback: fallback,
            primaryArtistOnly: store.selected.usePrimaryArtistOnly
        )
    }

    private var exampleFileName: String {
        example(for: store.selected.fileTemplate, fallback: "Untitled") + "." + exampleTrack.url.pathExtension
    }

    private var confirmMessage: String {
        let conflicts = model.conflictCount
        var text = "Files move inside your library folder"
        if let root = library.rootURL { text += ", \(root.lastPathComponent)" }
        text += "."
        if conflicts > 0 {
            text += " \(conflicts) conflict\(conflicts == 1 ? "" : "s") will get a number added to the file name."
        }
        return text + " Playlists follow the files."
    }

    // MARK: - Builder column

    private var builderColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 20) {
                    Text("Organizer")
                        .font(.system(size: 56, weight: .heavy))
                        .tracking(-2.2)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    profileControls
                }
                Text("Decide how your library is sorted into folders and named on disk.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 10)

                rulePath
                    .padding(.top, 36)

                section("Folders", subtitle: "Each level nests inside the one above. Files land in the deepest folder.") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.selected.levels.enumerated()), id: \.element.id) { index, level in
                            levelRow(level, index: index)
                        }
                        Button("+ Add level", action: addLevel)
                            .buttonStyle(QuietTextButtonStyle())
                            .padding(.leading, -10)
                            .padding(.top, 10)
                            .help("Add another folder level below the last one")
                            .overlay(alignment: .top) { divider }
                    }
                }

                section("File name", subtitle: "How each file is named inside its folder.") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            templateField(
                                text: Binding(
                                    get: { store.selected.fileTemplate },
                                    set: { newValue in mutateProfile { $0.fileTemplate = newValue } }
                                ),
                                target: .filename,
                                size: 15
                            )
                            Text(".\(exampleTrack.url.pathExtension)")
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        exampleLine(exampleFileName)
                    }
                }

                section("Tags", subtitle: nil) {
                    tagChips
                }

                section("Options", subtitle: nil) {
                    VStack(spacing: 0) {
                        optionRow(
                            title: "Use primary artist only",
                            subtitle: "For tracks credited to several artists (\u{201C}A & B\u{201D}, \u{201C}A feat. B\u{201D}, \u{201C}A; B\u{201D}), file under just the first.",
                            isOn: Binding(
                                get: { store.selected.usePrimaryArtistOnly },
                                set: { newValue in mutateProfile { $0.usePrimaryArtistOnly = newValue } }
                            )
                        )
                        optionRow(
                            title: "Delete empty original folders",
                            subtitle: "After moving, remove source folders with no audio left in them (cover art and other leftovers go too).",
                            isOn: Binding(
                                get: { store.selected.deleteEmptyOriginals },
                                set: { newValue in mutateProfile { $0.deleteEmptyOriginals = newValue } }
                            )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, topBarInset + 34)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.automatic)
    }

    private func section<Content: View>(_ title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            content()
                .padding(.top, 14)
        }
        .padding(.top, 40)
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    /// The whole rule as one large path: the library folder, each level's
    /// example folder name, then the example file name.
    private var rulePath: some View {
        let root = library.rootURL?.lastPathComponent ?? "Library"
        var text = Text(root + " / ").foregroundColor(Theme.textTertiary)
        for level in store.selected.levels {
            text = text
                + Text(example(for: level.nameTemplate, fallback: level.displayLabel)).foregroundColor(Theme.textPrimary)
                + Text(" / ").foregroundColor(Theme.textTertiary)
        }
        text = text + Text(exampleFileName).foregroundColor(Theme.textSecondary)

        return VStack(alignment: .leading, spacing: 12) {
            SheetLabel(text: "Every track lands at")
            text
                .font(.system(size: 26, weight: .heavy))
                .tracking(-0.5)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.2), value: store.selected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(Theme.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Profiles

    private var profileControls: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(store.profiles) { profile in
                    Button {
                        store.selectedID = profile.id
                        refreshPreview()
                    } label: {
                        if profile.id == store.selectedID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Section("New from preset") {
                    ForEach(OrganizerProfile.presets) { preset in
                        Button(preset.name) {
                            var fresh = preset
                            fresh.id = UUID()
                            fresh.levels = preset.levels.map {
                                HierarchyLevel(id: UUID(), groupBy: $0.groupBy, name: $0.name, nameTemplate: $0.nameTemplate)
                            }
                            store.add(fresh)
                            refreshPreview()
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(store.selected.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch profile, or start one from a preset")

            OrganizerIconButton(symbol: "pencil", help: "Rename profile") {
                renameDraft = store.selected.name
                showRename = true
            }
            OrganizerIconButton(symbol: "plus.square.on.square", help: "Duplicate profile") {
                store.duplicateSelected()
                refreshPreview()
            }
            OrganizerIconButton(symbol: "trash", help: "Delete profile", isEnabled: store.profiles.count > 1) {
                store.removeSelected()
                refreshPreview()
            }
            .disabled(store.profiles.count <= 1)
        }
    }

    private var renameSheet: some View {
        FLSheet(title: "Rename profile", width: 440, height: 220) {
            TextField("Profile name", text: $renameDraft)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 26, weight: .heavy)))
                .onSubmit { commitRename() }
                .padding(.top, 8)
        } footer: {
            Spacer()
            Button("Cancel") { showRename = false }
                .buttonStyle(SheetPillStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save") { commitRename() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            mutateProfile { $0.name = trimmed }
        }
        showRename = false
    }

    // MARK: - Folder levels

    /// grip · number · group by · folder name pattern · up / down / remove.
    private func levelRow(_ level: HierarchyLevel, index: Int) -> some View {
        let levelCount = store.selected.levels.count
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .draggable(level.id.uuidString) {
                    Text(level.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(6)
                        .background(Theme.surfaceElevated)
                }

            Text("\(index + 1)")
                .font(.system(size: 12, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18, alignment: .leading)

            groupMenu(for: level)
                .frame(width: 150, alignment: .leading)

            templateField(
                text: Binding(
                    get: { level.nameTemplate },
                    set: { newValue in
                        mutateProfile { profile in
                            if let i = profile.levels.firstIndex(where: { $0.id == level.id }) {
                                profile.levels[i].nameTemplate = newValue
                            }
                        }
                    }
                ),
                target: .level(level.id),
                size: 13.5
            )
            .help("Example: \(example(for: level.nameTemplate, fallback: level.displayLabel))")

            HStack(spacing: 0) {
                OrganizerIconButton(symbol: "chevron.up", size: 11, help: "Move up", isEnabled: index > 0) {
                    moveLevel(id: level.id, to: index - 1)
                }
                .disabled(index == 0)
                OrganizerIconButton(symbol: "chevron.down", size: 11, help: "Move down", isEnabled: index < levelCount - 1) {
                    moveLevel(id: level.id, to: index + 1)
                }
                .disabled(index >= levelCount - 1)
                OrganizerIconButton(symbol: "xmark", size: 10, help: "Remove level", isEnabled: levelCount > 1) {
                    mutateProfile { $0.levels.removeAll { $0.id == level.id } }
                    if activeTarget == .level(level.id) { activeTarget = .filename }
                }
                .disabled(levelCount <= 1)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { divider }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
            return moveLevel(id: draggedID, to: index)
        }
    }

    /// What the level groups by. Picking a field also resets the level's
    /// label and folder name pattern to that field's defaults; the pattern
    /// can then be edited freely.
    private func groupMenu(for level: HierarchyLevel) -> some View {
        Menu {
            ForEach(GroupingField.allCases) { field in
                Button {
                    mutateProfile { profile in
                        if let i = profile.levels.firstIndex(where: { $0.id == level.id }) {
                            profile.levels[i].groupBy = field
                            profile.levels[i].name = field.displayName
                            profile.levels[i].nameTemplate = field.defaultTemplate
                        }
                    }
                } label: {
                    if field == level.groupBy {
                        Label(field.displayName, systemImage: "checkmark")
                    } else {
                        Text(field.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(level.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Group this level by")
    }

    /// Moves a level to `destination`, clamped into range. Returns false when
    /// the move is a no-op so drop targets can reject it.
    @discardableResult
    private func moveLevel(id: UUID, to destination: Int) -> Bool {
        var profile = store.selected
        guard let from = profile.levels.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(destination, 0), profile.levels.count - 1)
        guard from != to else { return false }
        let level = profile.levels.remove(at: from)
        profile.levels.insert(level, at: to)
        store.selected = profile
        return true
    }

    private func addLevel() {
        let level = OrganizerProfile.newLevel()
        mutateProfile { $0.levels.append(level) }
        activeTarget = .level(level.id)
    }

    // MARK: - Fields and tags

    /// A template field drawn as plain text until hovered or focused. The
    /// field being typed in is also the one the tags insert into.
    private func templateField(text: Binding<String>, target: TemplateTarget, size: CGFloat) -> some View {
        OrganizerTemplateField(
            text: text,
            size: size,
            isActive: activeTarget == target,
            focus: $focusedField,
            target: target
        )
    }

    private func exampleLine(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text("Example:")
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12.5))
    }

    private var activeTargetName: String {
        switch activeTarget {
        case .filename:
            return "the file name"
        case .level(let id):
            let index = store.selected.levels.firstIndex(where: { $0.id == id }) ?? 0
            return "level \(index + 1)"
        }
    }

    private var tagChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(OrganizerTemplate.allTokens) { token in
                    OrganizerTokenChip(text: token.placeholder, help: "\(token.description). Adds to \(activeTargetName).") {
                        insert(token)
                    }
                }
            }
            (Text("Click a tag to add it to ")
                + Text(activeTargetName).foregroundColor(Theme.textSecondary).fontWeight(.semibold)
                + Text(". Hover one to see what it means."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func insert(_ token: OrganizerTemplate.Token) {
        mutateProfile { profile in
            switch activeTarget {
            case .filename:
                profile.fileTemplate += token.placeholder
            case .level(let id):
                if let i = profile.levels.firstIndex(where: { $0.id == id }) {
                    profile.levels[i].nameTemplate += token.placeholder
                }
            }
        }
    }

    private func optionRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .toggleStyle(FLSwitchStyle())
                .labelsHidden()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { divider }
    }

    // MARK: - Preview column

    private var previewColumn: some View {
        let tree = OrganizerPreviewTree.rows(for: model.operations, rootURL: library.rootURL)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.system(size: 20, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                Text(previewSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.operations.isEmpty {
                    counts.padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, topBarInset + 34)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.lastError {
                        inlineNotice(text: error, color: Theme.qualityLow)
                    } else if let message = model.lastResultMessage, model.operations.isEmpty {
                        inlineNotice(text: message, color: Theme.qualityCD)
                    }

                    if model.conflictCount > 0 {
                        inlineNotice(
                            text: "\(model.conflictCount) file\(model.conflictCount == 1 ? "" : "s") would land on the same name; a number gets added unless you change the file name.",
                            color: Theme.qualityMid
                        )
                    }

                    if tree.rows.isEmpty {
                        emptyPreviewState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tree.rows) { row in
                                previewRow(row)
                            }
                            if tree.hiddenTrackCount > 0 {
                                Text("+ \(tree.hiddenTrackCount) more track\(tree.hiddenTrackCount == 1 ? "" : "s") organized the same way")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.vertical, 8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }

            HStack(spacing: 14) {
                Text(applyFooterText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showApplyConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        if model.isApplying {
                            ProgressView().controlSize(.small)
                        }
                        Text(applyLabel)
                    }
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(!applyEnabled)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .overlay(alignment: .top) { divider }
        }
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.divider).frame(width: 1)
        }
    }

    private var counts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            count(model.moveCount, "to move", color: Theme.textPrimary)
            count(model.unchangedCount, "already in place", color: Theme.textTertiary)
            if model.conflictCount > 0 {
                count(model.conflictCount, model.conflictCount == 1 ? "conflict" : "conflicts", color: Theme.qualityMid)
            }
        }
    }

    private func count(_ n: Int, _ label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(n.formatted())
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var previewSubtitle: String {
        guard library.rootURL != nil else {
            return "Choose a library folder in Settings to see a preview."
        }
        if model.isRecomputing && model.operations.isEmpty {
            return "Working out where everything lands…"
        }
        return "Your library after organizing. Grey files are already where they belong."
    }

    private var applyEnabled: Bool {
        !model.isApplying
            && !model.isRecomputing
            && model.moveCount > 0
            && library.rootURL != nil
    }

    private var applyLabel: String {
        if model.isApplying { return "Organizing…" }
        if model.moveCount == 0 { return "Nothing to move" }
        return "Organize \(model.moveCount.formatted()) file\(model.moveCount == 1 ? "" : "s")"
    }

    private var applyFooterText: String {
        if library.rootURL == nil {
            return "Choose a library folder in Settings first."
        }
        if model.isRecomputing {
            return "Recalculating…"
        }
        if !model.operations.isEmpty && model.moveCount == 0 {
            return "Everything is already where this rule puts it."
        }
        return "Nothing moves until you confirm."
    }

    private func previewRow(_ row: OrganizerPreviewRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.kind == .folder ? "folder" : "music.note")
                .font(.system(size: 12))
                .foregroundStyle(row.isConflict ? Theme.qualityMid : Theme.textTertiary)
                .frame(width: 15)

            Text(row.label)
                .font(.system(size: 13, weight: row.kind == .folder ? .semibold : .regular))
                .foregroundStyle(previewRowColor(row))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if row.isConflict {
                Text("conflict")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.qualityMid)
            } else if row.isUnchanged {
                Text("in place")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            } else if let badge = row.badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .frame(height: 28)
    }

    private func previewRowColor(_ row: OrganizerPreviewRow) -> Color {
        if row.isConflict { return Theme.qualityMid }
        switch row.kind {
        case .folder: return Theme.textPrimary
        case .file: return row.isUnchanged ? Theme.textTertiary : Theme.textSecondary
        }
    }

    private var emptyPreviewState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isRecomputing ? "Building preview…" : "Nothing to preview yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(library.rootURL == nil
                 ? "Choose a library folder in Settings, then come back."
                 : "Once your library has been scanned, this shows how the rule reshapes it.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var applyOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("Organizing…")
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text(model.applyPhaseLabel ?? "Working…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                ProgressView(value: model.applyProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.textPrimary)
                    .padding(.top, 18)
                Text("Don't quit the app until this finishes.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(width: 440, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 50, y: 30)
        }
        .transition(.opacity)
    }

    private func inlineNotice(text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Building blocks

/// A monospaced template field drawn as plain text until hovered or focused,
/// with a faint fill once it's the one the tags will insert into.
private struct OrganizerTemplateField<Target: Hashable>: View {
    @Binding var text: String
    let size: CGFloat
    let isActive: Bool
    var focus: FocusState<Target?>.Binding
    let target: Target

    @State private var isHovering = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .focused(focus, equals: target)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.textPrimary.opacity(isActive ? 0.07 : (isHovering ? 0.045 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(isActive ? 0.12 : 0), lineWidth: 1)
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isActive)
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// Borderless circular icon button that fills its background on hover.
private struct OrganizerIconButton: View {
    let symbol: String
    var size: CGFloat = 12
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isHovering && isEnabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.textPrimary.opacity(isHovering && isEnabled ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Monospaced tag pill. Clicking adds the tag to whichever template is
/// active.
private struct OrganizerTokenChip: View {
    let text: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(Theme.textPrimary.opacity(isHovering ? 0.09 : 0.06))
                        .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(isHovering ? 0.12 : 0), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(help)
    }
}
