import SwiftUI
import AppKit

/// Two-stage sheet:
/// 1. `ImportDropView` collects a single audio file.
/// 2. Metadata editor pre-filled with values read from the file, letting the
///    user confirm or adjust before the track is added to the library.
struct ImportTrackView: View {
    @Environment(\.dismiss)         private var dismiss
    @Environment(\.metadataWriter)  private var writer
    @Environment(LibraryStore.self) private var library

    private enum Stage { case dropping, loading, editing }

    @State private var stage: Stage = .dropping
    @State private var sourceTrack: Track? = nil

    // Editable fields
    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var year: String = ""
    @State private var genre: String = ""
    @State private var trackNumber: String = ""

    @State private var artworkData: Data? = nil
    @State private var artworkChanged: Bool = false
    @State private var artworkRemoved: Bool = false

    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil

    private let scanner = LibraryScanner()

    var body: some View {
        FLSheet(title: "Import Track", width: 560, height: 620) {
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
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .dropping:
            ImportDropView(title: "Import Track", allowsMultiple: false) { urls in
                guard let url = urls.first else { return }
                loadTrack(from: url)
            }
            .padding(Theme.Spacing.xl)

        case .loading:
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Reading metadata…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .editing:
            editingForm
        }
    }

    private var editingForm: some View {
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
            .help("Click to choose cover artwork")

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
            ImportMetaField(label: "Song Name", text: $title, required: true)
            ImportMetaField(label: "Artist", text: $artist)
            ImportMetaField(label: "Album", text: $album)
            HStack(spacing: Theme.Spacing.md) {
                ImportMetaField(label: "Year", text: $year, width: 80, numericOnly: true)
                ImportMetaField(label: "Track #", text: $trackNumber, width: 80, numericOnly: true)
            }
            ImportMetaField(label: "Genre", text: $genre)
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .disabled(isSaving)

            Button(isSaving ? "Importing…" : "Import") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(
                    stage != .editing
                        || isSaving
                        || title.trimmingCharacters(in: .whitespaces).isEmpty
                )
        }
    }

    // MARK: - Actions

    private func loadTrack(from url: URL) {
        guard let stub = Track.makeFromURL(url) else {
            errorMessage = "Unsupported file format."
            return
        }
        stage = .loading
        Task {
            let loaded = await scanner.loadMetadata(for: stub)
            await MainActor.run { apply(loaded) }
        }
    }

    private func apply(_ track: Track) {
        sourceTrack = track
        title = track.title
        artist = track.artist ?? ""
        album = track.album ?? ""
        year = track.year.map { "\($0)" } ?? ""
        genre = track.genre ?? ""
        trackNumber = track.trackNumber.map { "\($0)" } ?? ""
        artworkData = track.artwork
        artworkChanged = false
        artworkRemoved = false
        stage = .editing
    }

    private func pickArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose cover artwork"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        artworkData = data
        artworkChanged = true
        artworkRemoved = false
    }

    private func save() {
        guard let source = sourceTrack else { return }
        guard let root = library.rootURL else {
            errorMessage = ImportCopy.Error.noLibraryRoot.localizedDescription
            return
        }
        isSaving = true

        let artChange: MetadataWriter.ArtworkChange
        if artworkRemoved {
            artChange = .removed
        } else if artworkChanged, let d = artworkData {
            artChange = .updated(d)
        } else {
            artChange = .unchanged
        }

        let parsedYear = Int(year)
        let parsedTrackNumber = Int(trackNumber)
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let filename = ImportCopy.trackFileName(
                    artist: artist.isEmpty ? nil : artist,
                    title: trimmedTitle,
                    pathExtension: source.url.pathExtension
                )
                let destURL = try ImportCopy.copy(source.url, into: root, named: filename)
                let destTrack = source.relocated(to: destURL)
                let updated = try await writer.write(
                    to: destTrack,
                    title: trimmedTitle,
                    artist: artist.isEmpty ? nil : artist,
                    album: album.isEmpty ? nil : album,
                    year: parsedYear,
                    genre: genre.isEmpty ? nil : genre,
                    trackNumber: parsedTrackNumber,
                    artworkChange: artChange
                )
                await MainActor.run {
                    library.addImportedTracks([updated])
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}

/// Shared compact metadata field used by every import editor. Visually matches
/// the field style in `TrackMetadataEditorView` / `AlbumMetadataEditorView`.
struct ImportMetaField: View {
    let label: String
    @Binding var text: String
    var required: Bool = false
    var width: CGFloat? = nil
    var numericOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                SheetLabel(text: label)
                if required {
                    Text("*")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.textPrimary.opacity(0.05))
                )
                .frame(width: width)
                .onChange(of: text) { _, v in
                    if numericOnly {
                        let filtered = v.filter(\.isNumber)
                        if filtered != v { text = filtered }
                    }
                }
        }
    }
}
