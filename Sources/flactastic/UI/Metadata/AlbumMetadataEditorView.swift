import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct EditableTrack: Identifiable {
    let id: UUID
    var title: String
    var artists: [String]
    var trackNumber: Int
    let originalTrack: Track
}

private struct TrackDropDelegate: DropDelegate {
    let toIndex: Int
    @Binding var tracks: [EditableTrack]
    @Binding var draggingIndex: Int?

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
            // so renumber everyone to match the new order. Track numbers are
            // otherwise left untouched (see EditableTrack.trackNumber) so
            // albums with sparse/non-contiguous numbering aren't silently
            // rewritten just by opening the editor.
            for i in tracks.indices {
                tracks[i].trackNumber = i + 1
            }
        }
        draggingIndex = toIndex
    }
}

/// Sheet for editing shared album-level metadata (album name, artist, year,
/// genre, artwork) plus per-track titles and order. Saves all values to every
/// track in the album via `MetadataWriter`, reassigning track numbers to match
/// the reordered list.
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

    @State private var artworkData:    Data?
    @State private var artworkChanged: Bool = false
    @State private var artworkRemoved: Bool = false
    @State private var pendingCropData: Data?

    @State private var editableTracks: [EditableTrack]
    @State private var draggingIndex:  Int?   = nil

    @State private var isSaving:     Bool    = false
    @State private var savedCount:   Int     = 0
    @State private var errorMessage: String? = nil

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
        let albumOwnerSource = album.albumArtist ?? album.artist
        let seeded = ArtistResolver.explicitlySeparated(albumOwnerSource ?? "")
            ?? (albumOwnerSource.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
        _albumArtists = State(initialValue: seeded)
        self.seededAlbumArtists = seeded
        self.albumArtistSeededFromRollUp = album.albumArtist == nil
        _year          = State(initialValue: album.year.map { "\($0)" } ?? "")
        _genre           = State(initialValue: album.genre ?? "")
        _secondaryGenres = State(initialValue: album.secondaryGenres)
        _isCompilation   = State(initialValue: album.isCompilation)
        _isMixCompilation = State(initialValue: album.isMixCompilation)
        _artworkData   = State(initialValue: album.artwork)
        let sorted = album.tracks.sorted {
            ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max)
        }
        _editableTracks = State(initialValue: sorted.enumerated().map { index, track in
            let chips = ArtistResolver.explicitlySeparated(track.artist ?? "")
                ?? (track.artist.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
            return EditableTrack(
                id: track.id,
                title: track.title,
                artists: chips,
                trackNumber: track.trackNumber ?? (index + 1),
                originalTrack: track
            )
        })
    }

    var body: some View {
        FLSheet(title: "Edit Album", width: 740, height: 780) {
            // One scroll for the whole form, so long tracklists don't sit in
            // a cramped inner list; the footer stays put.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    formBody
                    trackListSection
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
        } footer: {
            footerButtons
        }
        .alert("Save Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: Binding(
            get: { pendingCropData.map { CroppingPayload(data: $0) } },
            set: { if $0 == nil { pendingCropData = nil } }
        )) { payload in
            SquareImageCropperView(sourceData: payload.data) { cropped in
                artworkData    = cropped
                artworkChanged = true
                artworkRemoved = false
            }
        }
    }

    // MARK: - Form body

    /// Laid out like the album page: the cover, then the name in display
    /// type with the credits and details under it.
    private var formBody: some View {
        HStack(alignment: .top, spacing: 28) {
            artworkSection
            fieldsSection
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
    }

    private var artworkSection: some View {
        VStack(spacing: 6) {
            Button { pickArtwork() } label: {
                ArtworkView(data: artworkData, size: 184, showsShadow: false)
                    .overlay {
                        // "Change cover" shows on hover; "Add cover" when empty.
                        CoverEditOverlay(isEmpty: artworkData == nil)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
            }
            .buttonStyle(.plain)
            .help(artworkData == nil ? "Add album artwork" : "Change album artwork")
            .accessibilityLabel(artworkData == nil ? "Add cover" : "Change cover")

            if artworkData != nil {
                Button("Remove cover") {
                    artworkData    = nil
                    artworkChanged = false
                    artworkRemoved = true
                }
                .buttonStyle(QuietTextButtonStyle())
            }
        }
        .frame(width: 184)
        .disabled(isSaving)
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Album name", text: $albumName)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 34, weight: .heavy)))
                .accessibilityLabel("Album name")

            ArtistsFieldView(artists: $albumArtists, label: "Album Artist")

            HStack(alignment: .top, spacing: 16) {
                metaField("Year", text: $year, width: 80, numericOnly: true)
                GenreFieldView(text: $genre)
            }
            SecondaryGenresFieldView(genres: $secondaryGenres, primaryGenre: genre)

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
                        // Compilation and Mix Compilation are mutually exclusive.
                        if on { isCompilation = false }
                    }
            }
            .disabled(isSaving)
        }
    }

    /// Mix Compilation only makes sense for a single continuous recording —
    /// gated to albums with exactly one track that's also long enough to
    /// qualify (mirrors the per-track 10-minute rule in TrackMetadataEditorView).
    private var mixCompilationEligible: Bool {
        album.trackCount == 1 && (album.tracks.first?.duration ?? 0) > 600
    }

    @ViewBuilder
    private func metaField(
        _ label: String,
        text: Binding<String>,
        required: Bool = false,
        width: CGFloat? = nil,
        numericOnly: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SheetLabel(text: required ? "\(label) *" : label)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.textPrimary.opacity(0.05))
                )
                .frame(width: width)
                .accessibilityLabel(label)
                .onChange(of: text.wrappedValue) { _, v in
                    if numericOnly {
                        let filtered = v.filter(\.isNumber)
                        if filtered != v { text.wrappedValue = filtered }
                    }
                }
        }
    }

    // MARK: - Track list section

    /// One quiet row per track: number, title, artists, and a grip on the
    /// right to drag it to a new place (which renumbers the album).
    private var trackListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SheetLabel(text: "Tracks")
                Text("\(editableTracks.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("Drag to reorder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 2) {
                ForEach(editableTracks.indices, id: \.self) { index in
                    HStack(alignment: .center, spacing: 12) {
                        TextField("", text: trackNumberText(index))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 28)
                            .accessibilityLabel("Track number")

                        TextField("Title", text: $editableTracks[index].title)
                            .textFieldStyle(QuietFieldStyle(font: .system(size: 14.5, weight: .semibold)))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Title of track \(index + 1)")

                        ArtistsFieldView(
                            artists: $editableTracks[index].artists,
                            label: nil,
                            placeholder: "Artists…",
                            compact: true
                        )
                        .frame(maxWidth: .infinity)

                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(draggingIndex == index ? Theme.textPrimary : Theme.textTertiary)
                            .frame(width: 22, height: 30)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                            }
                            .onDrag {
                                draggingIndex = index
                                return NSItemProvider(object: "\(index)" as NSString)
                            }
                            .help("Drag to reorder")
                            .accessibilityLabel("Reorder track \(index + 1)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.textPrimary.opacity(draggingIndex == index ? 0.07 : 0))
                    )
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: TrackDropDelegate(
                            toIndex: index,
                            tracks: $editableTracks,
                            draggingIndex: $draggingIndex
                        )
                    )
                }
            }
            .padding(.horizontal, 16)
            .disabled(isSaving)
        }
        .padding(.top, 30)
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack(spacing: 10) {
            Text(isSaving
                 ? "Saved \(savedCount) of \(editableTracks.count)…"
                 : "Saves to all \(editableTracks.count) file\(editableTracks.count == 1 ? "" : "s").")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

            Button(isSaving ? "Saving…" : "Save") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(isSaving || albumName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Helpers

    /// Text binding for a track row's number field, backed directly by
    /// `EditableTrack.trackNumber` rather than the row's array position —
    /// edits here are independent of drag-reorder.
    private func trackNumberText(_ index: Int) -> Binding<String> {
        Binding(
            get: { String(editableTracks[index].trackNumber) },
            set: { newValue in
                let filtered = newValue.filter(\.isNumber)
                editableTracks[index].trackNumber = Int(filtered) ?? 0
            }
        )
    }

    /// Trim, drop empties, and serialise a chip list into the canonical
    /// `Artist A ; Artist B` form. Returns nil if the list is empty so the
    /// writer treats that as "clear the tag".
    private static func joinedChips(_ chips: [String]) -> String? {
        let cleaned = chips
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty { return nil }
        if cleaned.count == 1 { return cleaned[0] }
        return ArtistResolver.joinExplicit(cleaned)
    }

    // MARK: - Actions

    private func pickArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose album artwork"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        pendingCropData = data
    }

    private func save() {
        isSaving   = true
        savedCount = 0

        let artChange: MetadataWriter.ArtworkChange
        if artworkRemoved {
            artChange = .removed
        } else if artworkChanged, let d = artworkData {
            artChange = .updated(d)
        } else {
            artChange = .unchanged
        }

        let parsedYear = Int(year)
        let newAlbum   = albumName.trimmingCharacters(in: .whitespaces)
        let newGenre   = genre.isEmpty ? nil : genre
        let cleanedSecondary = secondaryGenres.filter { $0.lowercased() != genre.lowercased() }

        // Album-level artist — written to the ALBUMARTIST tag on every track.
        let newAlbumArtist: String? = Self.joinedChips(albumArtists)
        let aaChange: MetadataWriter.AlbumArtistChange = {
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
            if albumArtistSeededFromRollUp && albumArtists == seededAlbumArtists {
                return .unchanged
            }
            return .set(newAlbumArtist)
        }()

        // Compilation tag: only write when the toggle differs from the
        // album's current state (any track flagged) — avoids touching every
        // file on a no-op save.
        let compilationChange: MetadataWriter.CompilationChange = {
            isCompilation == album.isCompilation ? .unchanged : .set(isCompilation)
        }()

        // Mix Compilation: only ever reachable when the album has exactly one
        // track, so this writes through to that single track exactly like the
        // per-track editor would.
        let mixCompilationChange: MetadataWriter.MixCompilationChange = {
            isMixCompilation == album.isMixCompilation ? .unchanged : .set(isMixCompilation)
        }()

        let orderedTracks = editableTracks  // snapshot current order + edited fields

        Task {
            var collected: [Track] = []
            var firstError: String? = nil
            for item in orderedTracks {
                let newTitle = item.title.trimmingCharacters(in: .whitespaces)
                // Per-track artist: prefer the row's chips. If the user
                // cleared them entirely, inherit from the album-level chips
                // so we never write an empty artist tag for a track that
                // clearly belongs to the album's owner.
                let perTrackArtist = Self.joinedChips(item.artists) ?? newAlbumArtist
                do {
                    let updated = try await writer.write(
                        to: item.originalTrack,
                        title:             newTitle.isEmpty ? item.originalTrack.title : newTitle,
                        artist:            perTrackArtist,
                        album:             newAlbum,
                        year:              parsedYear,
                        genre:             newGenre,
                        secondaryGenres:   cleanedSecondary,
                        trackNumber:       item.trackNumber,
                        artworkChange:     artChange,
                        albumArtistChange: aaChange,
                        compilationChange: compilationChange,
                        mixCompilationChange: mixCompilationChange
                    )
                    collected.append(updated)
                    await MainActor.run { savedCount += 1 }
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            await MainActor.run {
                library.replaceTracks(collected)
                library.invalidateAlbumArtwork(albumID: album.id)
                isSaving = false
                if let err = firstError {
                    errorMessage = err
                } else {
                    dismiss()
                }
            }
        }
    }
}
