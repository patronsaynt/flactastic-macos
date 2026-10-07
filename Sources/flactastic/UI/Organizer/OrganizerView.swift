import SwiftUI

/// 5th tab: lets the user reshape their source folder by defining a folder
/// hierarchy and filename template, previewing the resulting layout, and
/// applying it. Two columns — a builder on the left, a live destination tree on
/// the right. The preview re-plans automatically (debounced) as the rules are
/// edited, and Apply is gated behind a confirmation because the operation moves
/// files in place.
struct OrganizerView: View {
    @Environment(\.topBarInset) private var topBarInset
    @Environment(LibraryStore.self) private var library
    @State private var store = OrganizerProfilesStore()
    @State private var model = OrganizerModel()
    @State private var showApplyConfirm = false
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var isTagGuideExpanded = false
    /// Which template the token chips and Tag Guide cards insert into. Survives
    /// the field losing focus when a chip is clicked.
    @State private var activeTarget: TemplateTarget = .filename
    @FocusState private var focusedField: TemplateTarget?
    @State private var draggingLevelID: UUID?

    private enum TemplateTarget: Hashable {
        case filename
        case level(UUID)
    }

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
        VStack(spacing: 0) {
            pageHeader
            Divider().background(Theme.divider)

            HStack(spacing: 0) {
                builderColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().background(Theme.divider)

                previewColumn
                    .frame(minWidth: 380, idealWidth: 440, maxWidth: 480, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, topBarInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay {
            if model.isApplying {
                applyOverlay
            }
        }
        .onChange(of: focusedField) { _, newValue in
            if let newValue { activeTarget = newValue }
        }
        .onChange(of: store.selected) { _, _ in refreshPreview() }
        .onChange(of: library.tracks.count) { _, _ in refreshPreview() }
        .onChange(of: library.rootURL) { _, _ in refreshPreview() }
        .task { refreshPreview() }
        .confirmationDialog(
            "Apply organization?",
            isPresented: $showApplyConfirm,
            titleVisibility: .visible
        ) {
            Button("Move \(model.moveCount) files", role: .destructive) {
                Task {
                    await model.apply(library: library, profile: store.selected)
                    refreshPreview()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will move files in place inside your source folder. \(model.conflictCount) conflict\(model.conflictCount == 1 ? "" : "s") will be resolved by appending a numeric suffix.")
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

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.10)))

            VStack(alignment: .leading, spacing: 3) {
                Text("Organizer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Define how your library gets sorted into folders and named on disk.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            profilePicker
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var profilePicker: some View {
        HStack(spacing: 6) {
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            OrganizerIconButton(symbol: "pencil", help: "Rename profile", isCircular: true) {
                renameDraft = store.selected.name
                showRename = true
            }
            OrganizerIconButton(symbol: "plus.square.on.square", help: "Duplicate profile", isCircular: true) {
                store.duplicateSelected()
                refreshPreview()
            }
            OrganizerIconButton(
                symbol: "trash",
                help: "Delete profile",
                tint: Theme.qualityLow.opacity(0.75),
                hoverTint: Theme.qualityLow,
                isEnabled: store.profiles.count > 1,
                isCircular: true
            ) {
                store.removeSelected()
                refreshPreview()
            }
            .disabled(store.profiles.count <= 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(
            Capsule()
                .fill(Theme.surface)
                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
        )
        .fixedSize()
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Rename profile")
                .font(Theme.Font.headline)
            TextField("Profile name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button("Cancel") { showRename = false }
                Button("Save") { commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 360)
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            mutateProfile { $0.name = trimmed }
        }
        showRename = false
    }

    // MARK: - Builder column

    private var builderColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    "Folder hierarchy",
                    subtitle: "Each level nests inside the one above — files land in the deepest folder."
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.selected.levels.enumerated()), id: \.element.id) { index, level in
                        levelRow(level, index: index)
                    }

                    addLevelButton
                }
                .padding(.top, 18)

                sectionDivider

                sectionHeader("File name", subtitle: "How each track file is named inside its final folder.")
                    .padding(.bottom, 16)

                filenameCard

                sectionDivider

                VStack(alignment: .leading, spacing: 18) {
                    settingRow(
                        title: "Use primary artist only",
                        subtitle: "For tracks credited to multiple artists (\u{201C}A & B\u{201D}, \u{201C}A feat. B\u{201D}, \u{201C}A; B\u{201D}), file under just the first.",
                        isOn: Binding(
                            get: { store.selected.usePrimaryArtistOnly },
                            set: { newValue in mutateProfile { $0.usePrimaryArtistOnly = newValue } }
                        )
                    )
                    settingRow(
                        title: "Delete empty original folders",
                        subtitle: "After moves complete, remove any source folders that no longer contain audio (cover art and other leftovers are swept up too).",
                        isOn: Binding(
                            get: { store.selected.deleteEmptyOriginals },
                            set: { newValue in mutateProfile { $0.deleteEmptyOriginals = newValue } }
                        )
                    )
                }

                sectionDivider

                tagGuide
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 60)
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.vertical, 30)
    }

    // MARK: - Hierarchy levels

    private func levelRow(_ level: HierarchyLevel, index: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if index > 0 {
                connectorRail
            }
            levelCard(level, index: index)
        }
        .padding(.leading, CGFloat(index) * 20)
        .opacity(draggingLevelID == level.id ? 0.4 : 1)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
            return moveLevel(id: draggedID, to: index)
        }
    }

    /// Elbow connecting a level to its parent, mirroring the design's rail: a
    /// vertical stem running up into the row above and a short horizontal stub
    /// into the card.
    private var connectorRail: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 2)
                .padding(.top, -14)
                .padding(.bottom, 20)
                .padding(.leading, 9)
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 11, height: 2)
                .padding(.leading, 9)
                .padding(.top, 20)
        }
        .frame(width: 20)
    }

    private func levelCard(_ level: HierarchyLevel, index: Int) -> some View {
        let isActive = activeTarget == .level(level.id)
        let levelCount = store.selected.levels.count

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .help("Drag to reorder")
                    .draggable(level.id.uuidString) {
                        Text(level.displayLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(6)
                            .background(Theme.surfaceElevated)
                    }

                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.accent)

                TextField(
                    level.groupBy.displayName,
                    text: Binding(
                        get: { level.name },
                        set: { newValue in
                            mutateProfile { profile in
                                if let i = profile.levels.firstIndex(where: { $0.id == level.id }) {
                                    profile.levels[i].name = newValue
                                }
                            }
                        }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: 150)

                Spacer(minLength: 0)

                OrganizerIconButton(
                    symbol: "chevron.up",
                    size: 12,
                    help: "Move up",
                    isEnabled: index > 0
                ) {
                    _ = moveLevel(id: level.id, to: index - 1)
                }
                .disabled(index == 0)

                OrganizerIconButton(
                    symbol: "chevron.down",
                    size: 12,
                    help: "Move down",
                    isEnabled: index < levelCount - 1
                ) {
                    _ = moveLevel(id: level.id, to: index + 1)
                }
                .disabled(index >= levelCount - 1)

                OrganizerIconButton(
                    symbol: "trash",
                    size: 12,
                    help: "Remove level",
                    tint: Theme.qualityLow.opacity(0.7),
                    hoverTint: Theme.qualityLow,
                    isEnabled: levelCount > 1
                ) {
                    mutateProfile { $0.levels.removeAll { $0.id == level.id } }
                    if activeTarget == .level(level.id) { activeTarget = .filename }
                }
                .disabled(levelCount <= 1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 0) {
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
                    target: .level(level.id)
                )

                exampleLine(example(for: level.nameTemplate, fallback: level.displayLabel))

                if isActive {
                    tokenChipRow
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isActive ? Theme.accent : Theme.divider, lineWidth: 1.5)
                )
        )
        .padding(.bottom, 14)
    }

    /// Moves the dragged level to `destination`, clamped into range. Returns
    /// false when the move is a no-op so drop targets can reject it.
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

    private var addLevelButton: some View {
        Button {
            let level = OrganizerProfile.newLevel()
            mutateProfile { $0.levels.append(level) }
            activeTarget = .level(level.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text("Add level")
                    .font(.system(size: 13))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: 36)
            .background(
                Capsule().strokeBorder(
                    Theme.divider,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
        }
        .buttonStyle(.plain)
        .help("Add another folder level below the last one")
    }

    // MARK: - File name

    private var filenameCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            templateField(
                text: Binding(
                    get: { store.selected.fileTemplate },
                    set: { newValue in mutateProfile { $0.fileTemplate = newValue } }
                ),
                target: .filename
            )

            exampleLine(
                example(for: store.selected.fileTemplate, fallback: "Untitled")
                    + "." + exampleTrack.url.pathExtension
            )

            tokenChipRow
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(activeTarget == .filename ? Theme.accent : Theme.divider, lineWidth: 1.5)
                )
        )
    }

    private func templateField(text: Binding<String>, target: TemplateTarget) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .focused($focusedField, equals: target)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(focusedField == target ? Theme.accent : Theme.divider, lineWidth: 1.5)
                    )
            )
    }

    private func exampleLine(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text("Example:")
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5))
        .padding(.top, 8)
    }

    private var tokenChipRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
                .padding(.bottom, 12)

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(OrganizerTemplate.allTokens) { token in
                    OrganizerTokenChip(text: token.placeholder, help: token.description) {
                        insert(token)
                    }
                }
            }
        }
        .padding(.top, 12)
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

    // MARK: - Toggles

    private func settingRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 16) {
            OrganizerPillToggle(isOn: isOn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Tag guide

    private var tagGuide: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isTagGuideExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isTagGuideExpanded ? 90 : 0))
                    Text("Tag guide")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(OrganizerTemplate.allTokens.count) tokens")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isTagGuideExpanded {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10, alignment: .leading),
                        GridItem(.flexible(), spacing: 10, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(OrganizerTemplate.allTokens) { token in
                        OrganizerTokenCard(token: token) { insert(token) }
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    // MARK: - Preview column

    private var previewColumn: some View {
        let tree = OrganizerPreviewTree.rows(for: model.operations, rootURL: library.rootURL)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Preview")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(previewSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.lastError {
                        inlineNotice(text: error, color: Theme.qualityLow)
                    } else if let message = model.lastResultMessage, model.operations.isEmpty {
                        inlineNotice(text: message, color: Theme.qualityCD)
                    }

                    if model.conflictCount > 0 {
                        inlineNotice(
                            text: "\(model.conflictCount) destination\(model.conflictCount == 1 ? "" : "s") collide — a numeric suffix will be appended unless you adjust the file name.",
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
                                    .padding(.leading, 44)
                                    .padding(.vertical, 8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.divider, lineWidth: 1))
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            Divider().background(Theme.divider)

            HStack(spacing: 12) {
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
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(model.isApplying ? "Applying…" : "Apply")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(applyEnabled ? Theme.background : Theme.textTertiary)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(Capsule().fill(applyEnabled ? Theme.accent : Theme.surfaceElevated))
                }
                .buttonStyle(.plain)
                .disabled(!applyEnabled)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .background(Theme.background)
    }

    private var previewSubtitle: String {
        guard library.rootURL != nil else {
            return "Choose a source folder in Settings to see a preview."
        }
        if model.isRecomputing && model.operations.isEmpty {
            return "Working out where everything lands…"
        }
        let count = library.tracks.count
        return "Updates live as you edit the rules. Showing how \(count) file\(count == 1 ? "" : "s") would land."
    }

    private var applyEnabled: Bool {
        !model.isApplying
            && !model.isRecomputing
            && model.moveCount > 0
            && library.rootURL != nil
    }

    private var applyFooterText: String {
        if library.rootURL == nil {
            return "Choose a source folder in Settings first."
        }
        if model.isRecomputing {
            return "Recalculating…"
        }
        if model.operations.isEmpty {
            return "No files will move until you apply."
        }
        if model.moveCount == 0 {
            return "Everything is already where these rules want it."
        }
        return "\(model.moveCount) file\(model.moveCount == 1 ? "" : "s") to move · \(model.unchangedCount) already in place. Nothing moves until you apply."
    }

    private func previewRow(_ row: OrganizerPreviewRow) -> some View {
        HStack(spacing: 9) {
            Image(systemName: row.kind == .folder ? "folder" : "doc")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(row.kind == .folder ? Theme.accent : Theme.textTertiary)
                .frame(width: 15)

            Text(row.label)
                .font(.system(size: 13))
                .foregroundStyle(previewRowColor(row))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if let badge = row.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(row.isConflict ? Theme.qualityMid : Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill((row.isConflict ? Theme.qualityMid : Theme.accent).opacity(0.10))
                    )
            }
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 22)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    private func previewRowColor(_ row: OrganizerPreviewRow) -> Color {
        if row.isConflict { return Theme.qualityMid }
        switch row.kind {
        case .folder: return Theme.textPrimary
        case .file: return row.isUnchanged ? Theme.textTertiary : Theme.textSecondary
        }
    }

    private var emptyPreviewState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text(model.isRecomputing ? "Building preview…" : "Nothing to preview yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(library.rootURL == nil
                 ? "Choose a source folder in Settings, then come back."
                 : "Scan a library folder to see how your rules reshape it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.divider, lineWidth: 1))
        )
    }

    private var applyOverlay: some View {
        ZStack {
            Theme.background.opacity(0.75).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.md) {
                ProgressView(value: model.applyProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 320)
                Text(model.applyPhaseLabel ?? "Working…")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("Don't quit the app until this finishes.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Spacing.xl)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.surfaceElevated))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.12)))
    }
}

// MARK: - Building blocks

/// Borderless icon button that fills its background on hover, matching the
/// design's `.fl-icbtn` treatment.
private struct OrganizerIconButton: View {
    let symbol: String
    var size: CGFloat = 13
    let help: String
    var tint: Color = Theme.textTertiary
    var hoverTint: Color = Theme.textPrimary
    var isEnabled: Bool = true
    var isCircular: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isHovering && isEnabled ? hoverTint : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: isCircular ? 13 : 8)
                        .fill(isHovering && isEnabled ? Theme.surfaceElevated : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Monospaced token pill. Clicking appends the token to whichever template is
/// currently active.
private struct OrganizerTokenChip: View {
    let text: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isHovering ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(isHovering ? Theme.accent.opacity(0.10) : Theme.surfaceElevated)
                        .overlay(Capsule().stroke(isHovering ? Theme.accent : Theme.divider, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Token + description card used in the expanded Tag guide grid.
private struct OrganizerTokenCard: View {
    let token: OrganizerTemplate.Token
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(token.placeholder)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Text(token.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isHovering ? Theme.accent.opacity(0.10) : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(isHovering ? Theme.accent : Theme.divider, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Insert \(token.placeholder)")
    }
}

/// Pill switch matching the design's `.fl-toggle` — 40×24 track with an 18pt
/// knob. Used instead of the stock macOS switch so the builder column keeps a
/// consistent look with the rest of the redesign.
private struct OrganizerPillToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Theme.divider)
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(.horizontal, 3)
            }
            .frame(width: 40, height: 24)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
