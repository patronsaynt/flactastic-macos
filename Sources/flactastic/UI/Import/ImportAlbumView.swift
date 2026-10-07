import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct ImportEditableTrack: Identifiable {
    let id: UUID
    var title: String
    var source: Track
}

private struct ImportTrackDropDelegate: DropDelegate {
    let toIndex: Int
    @Binding var tracks: [ImportEditableTrack]
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
        }
        draggingIndex = toIndex
    }
}

/// Two-stage sheet for importing a multi-track album. Stage 1 collects files,
/// stage 2 edits album-wide metadata plus per-track titles and order. Every
/// selected file is written with the same album fields and a track number
/// derived from its final position in the list.
struct ImportAlbumView: View {
    @Environment(\.dismiss)         private var dismiss
    @Environment(\.metadataWriter)  private var writer
    @Environment(LibraryStore.self) private var library

    private enum Stage { case dropping, loading, editing }

    @State private var stage: Stage = .dropping

    @State private var albumName: String = ""
    @State private var artist: String = ""
    @State private var albumArtist: String = ""
    @State private var year: String = ""
    @State private var genre: String = ""

    @State private var artworkData: Data? = nil
    @State private var artworkChanged: Bool = false
    @State private var artworkRemoved: Bool = false
    @State private var pendingCropData: Data? = nil

    @State private var editableTracks: [ImportEditableTrack] = []
    @State private var draggingIndex: Int? = nil

    @State private var isSaving: Bool = false
    @State private var savedCount: Int = 0
    @State private var loadedCount: Int = 0
    @State private var totalToLoad: Int = 0
    @State private var errorMessage: String? = nil

    private let scanner = LibraryScanner()

    var body: some View {
        FLSheet(title: "Import Album", width: 520, height: 660) {
            content
        } footer: {
            footerButtons
        }
        .alert("Import Failed", isPresented: Binding(
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
                artworkData = cropped
                artworkChanged = true
                artworkRemoved = false
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .dropping:
            ImportDropView(title: "Import Album", allowsMultiple: true) { urls in
                loadTracks(from: urls)
            }
            .padding(Theme.Spacing.xl)

        case .loading:
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Reading metadata \(loadedCount) of \(totalToLoad)…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .editing:
            VStack(spacing: 0) {
                formBody
                Divider().foregroundStyle(Theme.divider)
                trackListSection
            }
        }
    }

    private var formBody: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            artworkSection
            fieldsSection
        }
        .padding(Theme.Spacing.xl)
    }

    private var artworkSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button { pickArtwork() } label: {
                ArtworkView(data: artworkData, size: 130)
                    .overlay { CoverEditOverlay(isEmpty: artworkData == nil) }
            }
            .buttonStyle(.plain)
            .help("Click to choose album artwork")

            if artworkData != nil {
                Button("Remove cover") {
                    artworkData = nil
                    artworkChanged = false
                    artworkRemoved = true
                }
                .buttonStyle(QuietTextButtonStyle())
            }
        }
        .frame(width: 130)
    }

    private var fieldsSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ImportMetaField(label: "Album Name", text: $albumName, required: true)
            ImportMetaField(label: "Artist", text: $artist)
            ImportMetaField(label: "Album Artist", text: $albumArtist)
            HStack(spacing: Theme.Spacing.md) {
                ImportMetaField(label: "Year", text: $year, width: 80, numericOnly: true)
                ImportMetaField(label: "Genre", text: $genre)
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text(isSaving
                    ? "Imported \(savedCount) of \(editableTracks.count)…"
                    : "Applies to \(editableTracks.count) track\(editableTracks.count == 1 ? "" : "s")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var trackListSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SheetLabel(text: "Tracks")
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.md)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(editableTracks.indices, id: \.self) { index in
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("\(index + 1)")
                                .font(Theme.Font.captionMono)
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 24, alignment: .trailing)

                            TextField("", text: $editableTracks[index].title)
                                .textFieldStyle(.plain)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Theme.textPrimary.opacity(0.05))
                                )

                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(
                                    draggingIndex == index
                                        ? Theme.accent.opacity(0.8)
                                        : Theme.textTertiary.opacity(0.6)
                                )
                                .frame(width: 18)
                                .onDrag {
                                    draggingIndex = index
                                    return NSItemProvider(object: "\(index)" as NSString)
                                }
                        }
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, 2)
                        .background(
                            draggingIndex == index
                                ? Theme.textPrimary.opacity(0.07)
                                : Color.clear
                        )
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: ImportTrackDropDelegate(
                                toIndex: index,
                                tracks: $editableTracks,
                                draggingIndex: $draggingIndex
                            )
                        )
                    }
                }
                .padding(.bottom, Theme.Spacing.md)
            }
            .frame(maxHeight: 210)
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .disabled(isSaving)

            Button(isSaving ? "Importing…" : "Import Album") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(
                    stage != .editing
                        || isSaving
                        || albumName.trimmingCharacters(in: .whitespaces).isEmpty
                        || editableTracks.isEmpty
                )
        }
    }

    // MARK: - Actions

    private func loadTracks(from urls: [URL]) {
        let stubs = urls.compactMap(Track.makeFromURL)
        guard !stubs.isEmpty else {
            errorMessage = "No supported audio files in selection."
            return
        }
        stage = .loading
        totalToLoad = stubs.count
        loadedCount = 0

        Task {
            var loaded: [Track] = []
            for stub in stubs {
                let t = await scanner.loadMetadata(for: stub)
                loaded.append(t)
                await MainActor.run { loadedCount += 1 }
            }
            await MainActor.run { applyLoaded(loaded) }
        }
    }

    private func applyLoaded(_ tracks: [Track]) {
        let sorted = tracks.sorted { ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max) }
        editableTracks = sorted.map {
            ImportEditableTrack(id: $0.id, title: $0.title, source: $0)
        }

        // Autofill album-level fields from the most common non-empty value.
        albumName = mostCommon(sorted.compactMap { $0.album }) ?? ""
        artist = mostCommon(sorted.compactMap { $0.artist }) ?? ""
        albumArtist = mostCommon(sorted.compactMap { $0.albumArtist }) ?? ""
        year = (mostCommon(sorted.compactMap { $0.year })).map { "\($0)" } ?? ""
        genre = mostCommon(sorted.compactMap { $0.genre }) ?? ""
        artworkData = sorted.first(where: { $0.artwork != nil })?.artwork
        artworkChanged = false
        artworkRemoved = false

        stage = .editing
    }

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
        guard let root = library.rootURL else {
            errorMessage = ImportCopy.Error.noLibraryRoot.localizedDescription
            return
        }
        isSaving = true
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
        let newAlbum = albumName.trimmingCharacters(in: .whitespaces)
        let newArtist = artist.isEmpty ? nil : artist
        let newGenre = genre.isEmpty ? nil : genre
        let trimmedAA = albumArtist.trimmingCharacters(in: .whitespaces)
        let aaChange: MetadataWriter.AlbumArtistChange = trimmedAA.isEmpty
            ? .set(nil)
            : .set(trimmedAA)

        // Album folder: prefer album-artist over artist so compilations filed
        // under a single album artist don't split across per-track-artist folders.
        let folderArtist = trimmedAA.isEmpty ? (newArtist ?? "") : trimmedAA
        let folderName = ImportCopy.albumFolderName(artist: folderArtist, album: newAlbum)
        let destDirectory = root.appendingPathComponent(folderName, isDirectory: true)

        let ordered = editableTracks

        Task {
            var collected: [Track] = []
            var firstError: String? = nil
            for (index, item) in ordered.enumerated() {
                let newTitle = item.title.trimmingCharacters(in: .whitespaces)
                do {
                    let resolvedTitle = newTitle.isEmpty ? item.source.title : newTitle
                    let filename = ImportCopy.trackFileName(
                        artist: newArtist,
                        title: resolvedTitle,
                        pathExtension: item.source.url.pathExtension
                    )
                    let destURL = try ImportCopy.copy(item.source.url, into: destDirectory, named: filename)
                    let destTrack = item.source.relocated(to: destURL)
                    let updated = try await writer.write(
                        to: destTrack,
                        title: newTitle.isEmpty ? destTrack.title : newTitle,
                        artist: newArtist,
                        album: newAlbum,
                        year: parsedYear,
                        genre: newGenre,
                        trackNumber: index + 1,
                        artworkChange: artChange,
                        albumArtistChange: aaChange
                    )
                    collected.append(updated)
                    await MainActor.run { savedCount += 1 }
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            await MainActor.run {
                if !collected.isEmpty {
                    library.addImportedTracks(collected)
                }
                isSaving = false
                if let err = firstError {
                    errorMessage = err
                } else {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Helpers

    private func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }
}
