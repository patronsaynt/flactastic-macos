import SwiftUI
import AppKit

/// Two-stage sheet for importing a group of files as a new playlist. Stage 1
/// collects files, stage 2 asks only for playlist-level info (name,
/// description, cover). Per-file metadata is left untouched — the user can
/// edit individual tracks later from the track list.
struct ImportPlaylistView: View {
    @Environment(\.dismiss)          private var dismiss
    @Environment(LibraryStore.self)  private var library
    @Environment(PlaylistStore.self) private var playlistStore

    private enum Stage { case dropping, loading, editing }

    @State private var stage: Stage = .dropping
    @State private var loadedTracks: [Track] = []
    @State private var loadedCount: Int = 0
    @State private var totalToLoad: Int = 0

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var artworkData: Data? = nil
    @State private var pendingCropData: Data? = nil

    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil

    private let scanner = LibraryScanner()

    var body: some View {
        FLSheet(title: "Import Files as Playlist", width: 520, height: 520) {
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
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .dropping:
            ImportDropView(title: "Import Files as Playlist", allowsMultiple: true) { urls in
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
            .help("Click to choose a cover image")

            if artworkData != nil {
                Button("Remove") { artworkData = nil }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .buttonStyle(.plain)
            }
        }
        .frame(width: 130)
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                SheetLabel(text: "Name")
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.05))
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    SheetLabel(text: "Description")
                    Spacer()
                    Text("\(description.count)/\(Playlist.descriptionMaxLength)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(
                            description.count > Playlist.descriptionMaxLength
                                ? Theme.accent
                                : Theme.textTertiary
                        )
                }
                TextEditor(text: $description)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .frame(height: 100)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.05))
                    )
                    .onChange(of: description) { _, v in
                        if v.count > Playlist.descriptionMaxLength {
                            description = String(v.prefix(Playlist.descriptionMaxLength))
                        }
                    }
            }

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text("\(loadedTracks.count) track\(loadedTracks.count == 1 ? "" : "s")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .disabled(isSaving)

            Button(isSaving ? "Creating…" : "Create Playlist") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(
                    stage != .editing
                        || isSaving
                        || name.trimmingCharacters(in: .whitespaces).isEmpty
                        || loadedTracks.isEmpty
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
            await MainActor.run {
                loadedTracks = loaded
                if name.isEmpty {
                    name = suggestedPlaylistName(for: loaded)
                }
                stage = .editing
            }
        }
    }

    private func pickArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a playlist cover image"
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

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        let sources = loadedTracks

        Task {
            var copied: [Track] = []
            var firstError: String? = nil
            for source in sources {
                do {
                    let filename = ImportCopy.trackFileName(
                    artist: source.artist,
                    title: source.title,
                    pathExtension: source.url.pathExtension
                )
                let destURL = try ImportCopy.copy(source.url, into: root, named: filename)
                    copied.append(source.relocated(to: destURL))
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }

            await MainActor.run {
                if !copied.isEmpty {
                    library.addImportedTracks(copied)

                    // Resolve by URL so we pass the library's canonical Track
                    // instances (with stable ids) into the playlist.
                    let byURL = Dictionary(
                        library.tracks.map { ($0.url, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let resolved = copied.compactMap { byURL[$0.url] }

                    let playlist = playlistStore.createPlaylist(name: trimmedName)
                    playlistStore.addTracks(resolved, to: playlist.id, relativeTo: library.rootURL)
                    playlistStore.updatePlaylistMetadata(
                        id: playlist.id,
                        name: trimmedName,
                        description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                        customArtwork: artworkData
                    )
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

    private func suggestedPlaylistName(for tracks: [Track]) -> String {
        if let album = tracks.first?.album, !album.isEmpty,
           tracks.allSatisfy({ ($0.album ?? "") == album }) {
            return album
        }
        return "New Playlist"
    }
}
