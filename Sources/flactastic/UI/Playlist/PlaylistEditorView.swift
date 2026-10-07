import SwiftUI
import AppKit

/// Sheet for editing a playlist's user-facing metadata: name, custom cover
/// image, and description (capped at `Playlist.descriptionMaxLength`).
struct PlaylistEditorView: View {
    let playlistID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(LibraryStore.self) private var library

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var artworkData: Data?
    @State private var didLoad = false
    @State private var pendingCropData: Data?
    /// The playlist's tracks, for the cover it shows without a custom one
    /// and the summary in the footer.
    @State private var tracks: [Track] = []

    var body: some View {
        FLSheet(title: "Edit Playlist", width: 660, height: 420) {
            formBody
        } footer: {
            footerButtons
        }
        .onAppear(perform: loadIfNeeded)
        .sheet(item: Binding(
            get: { pendingCropData.map { CroppingPayload(data: $0) } },
            set: { if $0 == nil { pendingCropData = nil } }
        )) { payload in
            SquareImageCropperView(sourceData: payload.data) { cropped in
                artworkData = cropped
            }
        }
    }

    // MARK: - Form

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
                // Without a custom cover, the playlist's own (its first
                // track's art) shows under "Add cover".
                ArtworkView(data: artworkData ?? tracks.first?.artwork, size: 200, showsShadow: false)
                    .overlay { CoverEditOverlay(isEmpty: artworkData == nil) }
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
            }
            .buttonStyle(.plain)
            .help(artworkData == nil ? "Choose a custom cover image" : "Change the cover image")
            .accessibilityLabel(artworkData == nil ? "Add cover" : "Change cover")

            if artworkData != nil {
                Button("Remove cover") { artworkData = nil }
                    .buttonStyle(QuietTextButtonStyle())
            }
        }
        .frame(width: 200)
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Playlist name", text: $name)
                .textFieldStyle(QuietFieldStyle(font: .system(size: 34, weight: .heavy)))
                .accessibilityLabel("Playlist name")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SheetLabel(text: "Description")
                    Spacer()
                    Text("\(description.count)/\(Playlist.descriptionMaxLength)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(
                            description.count >= Playlist.descriptionMaxLength
                                ? Theme.textPrimary
                                : Theme.textTertiary
                        )
                }
                TextEditor(text: $description)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .frame(height: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.05))
                    )
                    .accessibilityLabel("Description")
                    .onChange(of: description) { _, v in
                        if v.count > Playlist.descriptionMaxLength {
                            description = String(v.prefix(Playlist.descriptionMaxLength))
                        }
                    }
            }
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack(spacing: 10) {
            Text(FormatUtils.playlistSummary(
                trackCount: tracks.count,
                duration: tracks.reduce(0) { $0 + ($1.duration ?? 0) }
            ))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SheetPillStyle())
                .keyboardShortcut(.cancelAction)

            Button("Save") { save() }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !didLoad,
              let playlist = playlistStore.playlists.first(where: { $0.id == playlistID }) else { return }
        name = playlist.name
        description = playlist.description ?? ""
        artworkData = playlist.customArtwork
        tracks = playlistStore.resolvedTracks(for: playlist, in: library)
        didLoad = true
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
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        playlistStore.updatePlaylistMetadata(
            id: playlistID,
            name: trimmedName,
            description: trimmedDesc.isEmpty ? nil : trimmedDesc,
            customArtwork: artworkData
        )
        dismiss()
    }
}
