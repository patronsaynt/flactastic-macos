import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct EditableTrack: Identifiable {
    let id: UUID
    var title: String
    var artists: [String]
    var trackNumber: Int
    /// A genre set on just this track from the selection bar; nil keeps the
    /// album's.
    var genre: String?
    var originalTrack: Track
}

private struct TrackDropDelegate: DropDelegate {
    let toIndex: Int
    @Binding var tracks: [EditableTrack]
    @Binding var draggingIndex: Int?
    /// Where the discs split. Positional, so a track dragged across a break
    /// changes disc.
    let discBreaks: Set<Int>

    func performDrop(info: DropInfo) -> Bool {
        draggingIndex = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let from = draggingIndex, from != toIndex else { return }
        withAnimation(.default) {
            tracks.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: from < toIndex ? toIndex + 1 : toIndex
            )
            // Dragging expresses an explicit intent to resequence the album,
            // so renumber everyone to match the new order, from 1 on each
            // disc. Track numbers are otherwise left untouched (see
            // EditableTrack.trackNumber) so albums with sparse/non-contiguous
            // numbering aren't silently rewritten just by opening the editor.
            let numbers = DiscLayout.trackNumbers(count: tracks.count, breaks: discBreaks)
            for i in tracks.indices {
                tracks[i].trackNumber = numbers[i]
            }
        }
        draggingIndex = toIndex
    }
}

/// What one track's file will be written with, and how that differs from
/// what's there now.
private struct PlannedWrite {
    let item: EditableTrack
    let title: String
    let artist: String?
    let genre: String?
    let discChange: MetadataWriter.DiscChange
    let change: FileChange
}

/// One track in Edit Album. Its own view, holding its own hover, so moving
/// the pointer over the list (as scrolling does) redraws just the rows it
/// crosses, not the whole sheet.
private struct AlbumTrackRow: View {
    @Binding var item: EditableTrack
    let index: Int
    let isSelected: Bool
    let anySelected: Bool
    let isDragging: Bool
    /// The disc this track would start; nil where it can't start one.
    let nextDisc: Int?
    let toggleSelect: () -> Void
    let startDisc: () -> Void
    let open: () -> Void
    let beginDrag: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: toggleSelect) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                    .opacity(isSelected || hovered || anySelected ? 1 : 0.45)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(item.title)" : "Select \(item.title)")

            TextField("", text: Binding(
                get: { String(item.trackNumber) },
                set: { item.trackNumber = Int($0.filter(\.isNumber)) ?? 0 }
            ))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 28)
            .accessibilityLabel("Track number")

            TextField("Title", text: $item.title)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 14.5, weight: .semibold)))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Title of track \(index + 1)")

            ArtistsFieldView(artists: $item.artists, label: nil, placeholder: "Artists…", compact: true)
                .frame(maxWidth: .infinity)

            if let g = item.genre {
                Text(g)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().strokeBorder(Theme.textPrimary.opacity(0.18)))
                    .help("This track's own genre")
            }

            Text(FormatUtils.formatDuration(item.originalTrack.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)

            if let nextDisc {
                icon("opticaldisc", help: "Start Disc \(nextDisc) with this track", action: startDisc)
                    .opacity(hovered ? 1 : 0)
            } else {
                Color.clear.frame(width: 24, height: 30)
            }
            icon("chevron.right", help: "Open in Edit Track: details, lyrics and markers", action: open)
                .opacity(hovered ? 1 : 0)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDragging ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .onDrag {
                    beginDrag()
                    return NSItemProvider(object: "\(index)" as NSString)
                }
                .help("Drag to reorder, or to another disc")
                .accessibilityLabel("Reorder track \(index + 1)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.textPrimary.opacity(isSelected ? 0.09 : isDragging ? 0.07 : hovered ? 0.035 : 0))
        )
        .onHover { hovered = $0 }
    }

    private func icon(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textTertiary)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct OpenedTrack: Identifiable {
    let id: UUID
    let track: Track
}

/// Edit Album: the cover beside the album's own fields across the top, as
/// on the album page, and every track below in its disc. Tracks can be
/// renamed, credited, renumbered, dragged between discs, selected together
/// to set their artists or genre, or opened in Edit Track.
///
/// Nothing is written until Review Changes shows, file by file, every tag
/// that will change; then Write saves them, marking each file, and any that
/// fail say why and can be retried.
struct AlbumMetadataEditorView: View {
    let album: Album

    @Environment(\.dismiss)         private var dismiss
    @Environment(\.metadataWriter)  private var writer
    @Environment(LibraryStore.self) private var library

    @State private var albumName:     String
    @State private var albumArtists:  [String]
    @State private var year:          String
    @State private var genre:           String
    @State private var secondaryGenres: [String]
    @State private var isCompilation:   Bool
    @State private var isMixCompilation: Bool
    @State private var label:           String

    @State private var artworkData:    Data?
    @State private var artworkChanged: Bool = false
    @State private var artworkRemoved: Bool = false

    @State private var editableTracks: [EditableTrack]
    @State private var draggingIndex:  Int?   = nil
    /// Positions where a new disc starts (see DiscLayout).
    @State private var discBreaks:     Set<Int>
    @State private var selection:      Set<UUID> = []
    @State private var bulkArtists:    [String] = []
    @State private var bulkGenre:      String = ""
    @State private var showBulkArtists = false
    @State private var showBulkGenre   = false
    @State private var opened:         OpenedTrack?
    /// The track last opened in Edit Track, to pick up what it wrote.
    @State private var lastOpenedID:   UUID?

    @State private var session = MetadataWriteSession()
    @State private var size = Self.fittedSize()
    /// Tracks written so far, put into the library once writing stops.
    @State private var written: [UUID: Track] = [:]

    /// True when the Album Artist field was seeded from `album.artist` (the
    /// per-track roll-up) because the album carries no real ALBUMARTIST tag.
    /// That roll-up can be the synthetic label "Various Artists", which exists
    /// only for display — writing it to disk would invent metadata the user
    /// never typed, and silently refile the album under a bogus artist.
    private let albumArtistSeededFromRollUp: Bool
    /// The chips the field started with, so save can tell an untouched seed
    /// from a deliberate edit.
    private let seededAlbumArtists: [String]

    init(album: Album) {
        self.album = album
        _albumName    = State(initialValue: album.name)
        // The single chip-based artist field represents the album-level
        // owning entity. Prefer the existing albumArtist tag; fall back to
        // album.artist (the per-track artist roll-up) so editing a record
        // missing an explicit ALBUMARTIST tag still surfaces a sensible
        // starting list.
        let seeded = TagText.chips(album.albumArtist ?? album.artist)
        _albumArtists = State(initialValue: seeded)
        self.seededAlbumArtists = seeded
        self.albumArtistSeededFromRollUp = album.albumArtist == nil
        _year          = State(initialValue: album.year.map { "\($0)" } ?? "")
        _genre           = State(initialValue: album.genre ?? "")
        _secondaryGenres = State(initialValue: album.secondaryGenres)
        _isCompilation   = State(initialValue: album.isCompilation)
        _isMixCompilation = State(initialValue: album.isMixCompilation)
        _label           = State(initialValue: album.label ?? "")
        _artworkData   = State(initialValue: album.artwork)
        let sorted = album.tracks.sorted {
            let discA = $0.discNumber ?? 1, discB = $1.discNumber ?? 1
            if discA != discB { return discA < discB }
            return ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max)
        }
        _discBreaks = State(initialValue: DiscLayout.breaks(forDiscs: sorted.map(\.discNumber)))
        _editableTracks = State(initialValue: sorted.enumerated().map { index, track in
            EditableTrack(
                id: track.id,
                title: track.title,
                artists: TagText.chips(track.artist),
                trackNumber: track.trackNumber ?? (index + 1),
                originalTrack: track
            )
        })
    }

    var body: some View {
        let plan = writePlan()
        let changes = plan.map(\.change)
        return VStack(spacing: 0) {
            MetadataEditorHeader(title: "Edit Album", close: requestClose) { EmptyView() }
            Group {
                if session.phase == .editing {
                    VStack(spacing: 0) {
                        headerBand
                        Rectangle().fill(Theme.divider).frame(height: 1)
                        trackList
                    }
                } else {
                    ReviewChangesPanel(changes: changes, session: session, reveal: reveal)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.divider).frame(height: 1)
            MetadataEditorFooter(
                session: session, changes: changes,
                blocker: albumName.trimmingCharacters(in: .whitespaces).isEmpty ? "The album needs a name." : nil,
                cancel: requestClose,
                write: { Task { await write(plan) } }
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.surface)
        .sheet(item: $opened, onDismiss: refreshOpened) { item in
            TrackMetadataEditorView(track: item.track, backLabel: albumName)
        }
    }

    /// The sheet's size, shrunk to fit a smaller window.
    private static func fittedSize() -> CGSize {
        let window = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentLayoutRect.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: min(1080, max(900, window.width - 40)), height: min(780, max(600, window.height - 40)))
    }

    // MARK: - Album

    /// Laid out like the album page: the cover, then the name in display
    /// type with the credits and details under it.
    private var headerBand: some View {
        HStack(alignment: .top, spacing: 28) {
            CoverWell(data: artworkData, album: albumName, artist: albumArtists.first ?? "") { data in
                artworkData = data
                artworkChanged = data != nil
                artworkRemoved = data == nil && album.artwork != nil
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Album name", text: $albumName)
                    .textFieldStyle(QuietFieldStyle(font: .system(size: 34, weight: .heavy)))
                    .accessibilityLabel("Album name")
                ArtistsFieldView(artists: $albumArtists, label: "Album Artists")
                HStack(alignment: .top, spacing: 18) {
                    QuietLabeledField(label: "Year", text: $year, placeholder: "YYYY", numeric: true)
                        .frame(width: 80)
                    GenreFieldView(text: $genre)
                        .frame(maxWidth: .infinity)
                    SecondaryGenresFieldView(genres: $secondaryGenres, primaryGenre: genre)
                        .frame(maxWidth: .infinity)
                    QuietLabeledField(label: "Record Label", text: $label, placeholder: "None")
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    SheetTogglePill(title: "Compilation", isOn: $isCompilation)
                        .onChange(of: isCompilation) { _, on in
                            // Compilation and Mix Compilation are mutually exclusive.
                            if on { isMixCompilation = false }
                        }
                    SheetTogglePill(title: "Mix Compilation", isOn: $isMixCompilation)
                        .disabled(!mixCompilationEligible && !isMixCompilation)
                        .help(mixCompilationEligible
                              ? "Mark this album's single track as a mix, live set, radio show, or concert recording. Disables lyrics and enables chapter markers."
                              : "Only available for single-track albums longer than 10 minutes")
                        .onChange(of: isMixCompilation) { _, on in
                            if on { isCompilation = false }
                        }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    /// Mix Compilation only makes sense for a single continuous recording —
    /// gated to albums with exactly one track that's also long enough to
    /// qualify (mirrors the per-track 10-minute rule in TrackMetadataEditorView).
    private var mixCompilationEligible: Bool {
        album.trackCount == 1 && (album.tracks.first?.duration ?? 0) > 600
    }

    // MARK: - Tracks

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 6) {
            trackToolbar
                .frame(height: 36)
                .padding(.horizontal, 28)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(editableTracks.indices, id: \.self) { index in
                        if index == 0 || discBreaks.contains(index) {
                            discHeader(at: index)
                        }
                        trackRow(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var trackToolbar: some View {
        HStack(spacing: 8) {
            if selection.isEmpty {
                Text("Tracks")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(editableTracks.count) track\(editableTracks.count == 1 ? "" : "s") · \(discBreaks.count + 1) disc\(discBreaks.isEmpty ? "" : "s")")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("Drag to reorder · hover a track to start a new disc there")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("\(selection.count) selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button("Set Artists…") { bulkArtists = []; showBulkArtists = true }
                    .buttonStyle(QuietTextButtonStyle())
                    .popover(isPresented: $showBulkArtists, arrowEdge: .bottom) { bulkArtistsPopover }
                Button("Set Genre…") { bulkGenre = ""; showBulkGenre = true }
                    .buttonStyle(QuietTextButtonStyle())
                    .popover(isPresented: $showBulkGenre, arrowEdge: .bottom) { bulkGenrePopover }
                Button("Deselect") { selection.removeAll() }
                    .buttonStyle(QuietTextButtonStyle())
                Spacer()
            }
        }
    }

    private var bulkArtistsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Artists for \(selection.count) track\(selection.count == 1 ? "" : "s")")
                .font(.system(size: 13.5, weight: .semibold))
            ArtistsFieldView(artists: $bulkArtists, label: nil)
            HStack {
                Spacer()
                Button("Apply") {
                    for i in editableTracks.indices where selection.contains(editableTracks[i].id) {
                        editableTracks[i].artists = bulkArtists
                    }
                    showBulkArtists = false
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(bulkArtists.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var bulkGenrePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Genre for \(selection.count) track\(selection.count == 1 ? "" : "s")")
                .font(.system(size: 13.5, weight: .semibold))
            GenreFieldView(text: $bulkGenre)
            Text("These tracks keep this genre instead of the album's.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Button("Use the Album's") {
                    for i in editableTracks.indices where selection.contains(editableTracks[i].id) {
                        editableTracks[i].genre = nil
                    }
                    showBulkGenre = false
                }
                .buttonStyle(QuietTextButtonStyle())
                Spacer()
                Button("Apply") {
                    for i in editableTracks.indices where selection.contains(editableTracks[i].id) {
                        editableTracks[i].genre = bulkGenre
                    }
                    showBulkGenre = false
                }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(bulkGenre.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// "Disc 2" over its tracks, with a button to merge it back into the
    /// disc before (none on Disc 1).
    private func discHeader(at index: Int) -> some View {
        let number = DiscLayout.disc(at: index, breaks: discBreaks)
        let end = (discBreaks.filter { $0 > index }.min() ?? editableTracks.count)
        return HStack(spacing: 10) {
            SheetLabel(text: "Disc \(number)")
            Text("\(end - index) track\(end - index == 1 ? "" : "s")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Rectangle().fill(Theme.textPrimary.opacity(0.08)).frame(height: 1)
            if index > 0 {
                Button("Merge into Disc \(number - 1)") { setDiscBreak(at: index, on: false) }
                    .buttonStyle(QuietTextButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, index == 0 ? 4 : 16)
        .padding(.bottom, 4)
    }

    private func trackRow(_ index: Int) -> some View {
        let item = editableTracks[index]
        let canSplit = index > 0 && !discBreaks.contains(index)
        return AlbumTrackRow(
            item: $editableTracks[index],
            index: index,
            isSelected: selection.contains(item.id),
            anySelected: !selection.isEmpty,
            isDragging: draggingIndex == index,
            nextDisc: canSplit ? DiscLayout.disc(at: index, breaks: discBreaks) + 1 : nil,
            toggleSelect: {
                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            },
            startDisc: { setDiscBreak(at: index, on: true) },
            open: {
                lastOpenedID = item.id
                opened = OpenedTrack(id: item.id, track: item.originalTrack)
            },
            beginDrag: { draggingIndex = index }
        )
        .onDrop(
            of: [UTType.plainText],
            delegate: TrackDropDelegate(toIndex: index, tracks: $editableTracks, draggingIndex: $draggingIndex, discBreaks: discBreaks)
        )
    }

    // MARK: - Helpers

    /// Adds or removes the disc break before `index`, then numbers every
    /// disc from 1: splitting or merging discs is a deliberate resequence.
    private func setDiscBreak(at index: Int, on: Bool) {
        withAnimation(.default) {
            if on { discBreaks.insert(index) } else { discBreaks.remove(index) }
            discBreaks = DiscLayout.clamped(discBreaks, count: editableTracks.count)
            let numbers = DiscLayout.trackNumbers(count: editableTracks.count, breaks: discBreaks)
            for i in editableTracks.indices {
                editableTracks[i].trackNumber = numbers[i]
            }
        }
    }

    /// After Edit Track, the row follows what it wrote, unless it's been
    /// edited here too.
    private func refreshOpened() {
        guard let id = lastOpenedID, let i = editableTracks.firstIndex(where: { $0.id == id }),
              let fresh = library.albums.lazy.flatMap(\.tracks).first(where: { $0.id == id }) else { return }
        let old = editableTracks[i].originalTrack
        if editableTracks[i].title == old.title { editableTracks[i].title = fresh.title }
        if editableTracks[i].artists == TagText.chips(old.artist) { editableTracks[i].artists = TagText.chips(fresh.artist) }
        editableTracks[i].originalTrack = fresh
    }

    private func reveal(_ id: UUID) {
        guard let track = editableTracks.first(where: { $0.id == id })?.originalTrack else { return }
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }

    private func requestClose() {
        guard session.phase != .writing else { return }
        commitWritten()
        dismiss()
    }

    // MARK: - Writing

    private var artChange: MetadataWriter.ArtworkChange {
        if artworkRemoved { return .removed }
        if artworkChanged, let d = artworkData { return .updated(d) }
        return .unchanged
    }

    /// Every file that will change, with what it'll be written with and the
    /// tags that differ from what's in it now. Files with nothing to change
    /// aren't rewritten.
    private func writePlan() -> [PlannedWrite] {
        let parsedYear = Int(year)
        let newAlbum   = albumName.trimmingCharacters(in: .whitespaces)
        let newGenre   = genre.isEmpty ? nil : genre
        let cleanedSecondary = secondaryGenres.filter { $0.lowercased() != genre.lowercased() }
        let newAlbumArtist = TagText.joined(albumArtists)
        let aaChange = albumArtistChange(newAlbumArtist)
        let compilationChange: MetadataWriter.CompilationChange = isCompilation == album.isCompilation ? .unchanged : .set(isCompilation)
        let mixChange: MetadataWriter.MixCompilationChange = isMixCompilation == album.isMixCompilation ? .unchanged : .set(isMixCompilation)
        let newLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelChange: MetadataWriter.LabelChange = newLabel == (album.label ?? "") ? .unchanged : .set(newLabel.isEmpty ? nil : newLabel)
        // Discs: a multi-disc layout writes each track's disc and the total.
        // Merged back to one disc clears the tags of an album that had
        // several; a single-disc album's own tags ("1/1" or none) are left alone.
        let discCount = discBreaks.count + 1
        let hadDiscTags = !album.discs.isEmpty || album.tracks.contains { ($0.discTotal ?? 1) > 1 }
        let art = artChange

        return editableTracks.enumerated().compactMap { position, item in
            let o = item.originalTrack
            let discChange: MetadataWriter.DiscChange =
                discCount > 1 ? .set(number: DiscLayout.disc(at: position, breaks: discBreaks), total: discCount)
                : hadDiscTags ? .set(number: nil, total: nil)
                : .unchanged
            let typedTitle = item.title.trimmingCharacters(in: .whitespaces)
            let title = typedTitle.isEmpty ? o.title : typedTitle
            // Per-track artist: prefer the row's chips. If the user cleared
            // them entirely, inherit from the album-level chips so we never
            // write an empty artist tag for a track that clearly belongs to
            // the album's owner.
            let artist = TagText.joined(item.artists) ?? newAlbumArtist
            let trackGenre = item.genre ?? newGenre

            var rows: [TagDiff] = []
            func diff(_ tag: String, _ old: String, _ new: String) {
                if old != new { rows.append(TagDiff(tag: tag, old: old, new: new)) }
            }
            diff("TITLE", o.title, title)
            diff("ARTIST", o.artist ?? "", artist ?? "")
            diff("ALBUM", o.album ?? "", newAlbum)
            diff("DATE", TagText.number(o.year), TagText.number(parsedYear))
            diff("GENRE", GenreResolver.join(primary: o.genre, secondary: o.secondaryGenres) ?? "",
                 GenreResolver.join(primary: trackGenre, secondary: cleanedSecondary) ?? "")
            diff("TRACKNUMBER", TagText.number(o.trackNumber), TagText.number(item.trackNumber))
            if case .set(let v) = aaChange { diff("ALBUMARTIST", o.albumArtist ?? "", v ?? "") }
            if case .set(let on) = compilationChange { diff("COMPILATION", o.isCompilation ? "Yes" : "No", on ? "Yes" : "No") }
            if case .set(let on) = mixChange { diff("MIX COMPILATION", o.isMixCompilation ? "Yes" : "No", on ? "Yes" : "No") }
            if case .set(let v) = labelChange { diff("LABEL", o.label ?? "", v ?? "") }
            if case .set(let number, let total) = discChange {
                diff("DISCNUMBER", TagText.number(o.discNumber), TagText.number(number))
                diff("DISCTOTAL", TagText.number(o.discTotal), TagText.number(total))
            }
            switch art {
            case .removed: diff("PICTURE", TagText.cover(o.artwork), "")
            case .updated(let d): if o.artwork != d { rows.append(TagDiff(tag: "PICTURE", old: TagText.cover(o.artwork), new: TagText.cover(d))) }
            case .unchanged: break
            }
            guard !rows.isEmpty else { return nil }
            return PlannedWrite(
                item: item, title: title, artist: artist, genre: trackGenre, discChange: discChange,
                change: FileChange(id: item.id, fileName: Self.displayPath(o.url), rows: rows)
            )
        }
    }

    private func albumArtistChange(_ newAlbumArtist: String?) -> MetadataWriter.AlbumArtistChange {
        let existing = album.albumArtist ?? ""
        let target = newAlbumArtist ?? ""
        if existing == target { return .unchanged }
        // Don't promote a display-only roll-up into a real tag. When the
        // album had no ALBUMARTIST, the field was pre-filled from
        // `album.artist` — which is "Various Artists" whenever the tracks
        // carry more than one distinct artist. Saving an untouched field
        // would stamp that label onto every file, and the Organizer would
        // then dutifully file the album under it. Only write what the user
        // actually changed.
        if albumArtistSeededFromRollUp && albumArtists == seededAlbumArtists { return .unchanged }
        return .set(newAlbumArtist)
    }

    /// The file's name, with its disc folder when it sits in one.
    static func displayPath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        let isDiscFolder = parent.lowercased().hasPrefix("disc") || parent.lowercased().hasPrefix("cd")
        return isDiscFolder ? "\(parent)/\(url.lastPathComponent)" : url.lastPathComponent
    }

    private func write(_ plan: [PlannedWrite]) async {
        let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.change.id, $0) })
        let parsedYear = Int(year)
        let newAlbum = albumName.trimmingCharacters(in: .whitespaces)
        let cleanedSecondary = secondaryGenres.filter { $0.lowercased() != genre.lowercased() }
        let aaChange = albumArtistChange(TagText.joined(albumArtists))
        let compilationChange: MetadataWriter.CompilationChange = isCompilation == album.isCompilation ? .unchanged : .set(isCompilation)
        let mixChange: MetadataWriter.MixCompilationChange = isMixCompilation == album.isMixCompilation ? .unchanged : .set(isMixCompilation)
        let newLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelChange: MetadataWriter.LabelChange = newLabel == (album.label ?? "") ? .unchanged : .set(newLabel.isEmpty ? nil : newLabel)
        let art = artChange
        let writer = writer

        // A server library takes one PATCH for every track sharing an edit
        // (§10); the first file of each group sends it for the rest.
        let server = await writer.server
        var edits: [UUID: TagEdit] = [:]
        if server != nil {
            for p in plan {
                edits[p.change.id] = TagEdit.from(
                    p.item.originalTrack, title: p.title, artist: p.artist, album: newAlbum, year: parsedYear,
                    genre: p.genre, secondaryGenres: cleanedSecondary, trackNumber: p.item.trackNumber,
                    artwork: art, albumArtist: aaChange, compilation: compilationChange, mix: mixChange,
                    label: labelChange, disc: p.discChange)
            }
        }
        let groups = Dictionary(grouping: plan, by: { edits[$0.change.id] })
        var batched: [UUID: Track] = [:]

        let allWritten = await session.write(plan.map(\.change)) { file in
            guard let p = byID[file.id] else { return }
            if let server, let edit = edits[file.id] {
                if batched[p.item.originalTrack.id] == nil {
                    let group = (groups[edit] ?? [p]).map(\.item.originalTrack)
                    for t in try await server.apply(edit, to: group) { batched[t.id] = t }
                }
                written[file.id] = batched[p.item.originalTrack.id] ?? p.item.originalTrack
                return
            }
            let updated = try await writer.write(
                to: p.item.originalTrack,
                title: p.title,
                artist: p.artist,
                album: newAlbum,
                year: parsedYear,
                genre: p.genre,
                secondaryGenres: cleanedSecondary,
                trackNumber: p.item.trackNumber,
                artworkChange: art,
                albumArtistChange: aaChange,
                compilationChange: compilationChange,
                mixCompilationChange: mixChange,
                labelChange: labelChange,
                discChange: p.discChange
            )
            written[file.id] = updated
        }
        commitWritten()
        if allWritten { dismiss() }
    }

    /// Puts what's been written into the library, once.
    private func commitWritten() {
        guard !written.isEmpty else { return }
        library.replaceTracks(Array(written.values))
        library.invalidateAlbumArtwork(albumID: album.id)
        written.removeAll()
    }
}
