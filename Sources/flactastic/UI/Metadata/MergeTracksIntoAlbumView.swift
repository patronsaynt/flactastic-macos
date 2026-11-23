import SwiftUI

/// Sheet presented when the user selects multiple tracks and chooses
/// "Merge into Album…". Writes a shared album name and album artist to every
/// selected track so the two-pass grouping in `LibraryStore.albums` brings
/// them all under one album card.
struct MergeTracksIntoAlbumView: View {
    let tracks: [Track]
    let onDone: () -> Void

    @Environment(\.dismiss)         private var dismiss
    @Environment(\.metadataWriter)  private var writer
    @Environment(LibraryStore.self) private var library

    @State private var albumName:   String
    @State private var artist:      String
    @State private var albumArtist: String
    @State private var isSaving:    Bool   = false
    @State private var savedCount:  Int    = 0
    @State private var errorMessage: String? = nil

    init(tracks: [Track], onDone: @escaping () -> Void) {
        self.tracks = tracks
        self.onDone = onDone
        // Pre-fill from the most common existing values.
        let commonAlbum   = tracks.compactMap(\.album).mostCommon() ?? ""
        let commonArtist  = tracks.compactMap(\.artist).mostCommon() ?? ""
        let commonAA      = tracks.compactMap(\.albumArtist).mostCommon() ?? ""
        _albumName   = State(initialValue: commonAlbum)
        _artist      = State(initialValue: commonArtist)
        _albumArtist = State(initialValue: commonAA)
    }

    var body: some View {
        FLSheet(title: "Merge into Album", width: 460, height: 510) {
            VStack(alignment: .leading, spacing: 0) {
                form
                Divider().foregroundStyle(Theme.divider)
                trackPreview
            }
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
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Set these fields on all \(tracks.count) selected tracks.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)

            metaField("Album Name", text: $albumName, required: true)
            metaField("Artist", text: $artist,
                      hint: "Applied to every track. Leave blank to keep each track's existing artist.")
            metaField("Album Artist", text: $albumArtist,
                      hint: "Shared album-level artist. Ensures tracks merge under one album.")
        }
        .padding(Theme.Spacing.xl)
    }

    @ViewBuilder
    private func metaField(
        _ label: String,
        text: Binding<String>,
        required: Bool = false,
        hint: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                if required {
                    Text("*").font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.surfaceElevated)
                )
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Track preview

    private var trackPreview: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("TRACKS TO MERGE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tracks) { track in
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "music.note")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 16)
                            Text(track.title)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textPrimary)
                            if let artist = track.artist {
                                Text("–")
                                    .foregroundStyle(Theme.textTertiary)
                                Text(artist)
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.bottom, Theme.Spacing.md)
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            if isSaving {
                Text("Saving \(savedCount) of \(tracks.count)…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PillButtonStyle())
                .disabled(isSaving)

            Button(isSaving ? "Saving…" : "Merge") { save() }
                .buttonStyle(PillButtonStyle(isPrimary: true))
                .disabled(isSaving || albumName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Save

    private func save() {
        isSaving   = true
        savedCount = 0

        let newAlbum    = albumName.trimmingCharacters(in: .whitespaces)
        let newArtist   = artist.trimmingCharacters(in: .whitespaces)
        let trimmedAA   = albumArtist.trimmingCharacters(in: .whitespaces)
        let aaChange: MetadataWriter.AlbumArtistChange = .set(trimmedAA.isEmpty ? nil : trimmedAA)

        Task {
            var collected: [Track] = []
            var firstError: String? = nil
            for track in tracks {
                do {
                    // If the artist field is filled, apply it to all tracks.
                    // If left blank, preserve each track's own existing artist.
                    let resolvedArtist = newArtist.isEmpty ? track.artist : newArtist
                    let updated = try await writer.write(
                        to: track,
                        title:             track.title,
                        artist:            resolvedArtist,
                        album:             newAlbum,
                        year:              track.year,
                        genre:             track.genre,
                        trackNumber:       track.trackNumber,
                        artworkChange:     .unchanged,
                        albumArtistChange: aaChange
                    )
                    collected.append(updated)
                    await MainActor.run { savedCount += 1 }
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            await MainActor.run {
                library.replaceTracks(collected)
                isSaving = false
                if let err = firstError {
                    errorMessage = err
                } else {
                    onDone()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Array where Element: Hashable {
    func mostCommon() -> Element? {
        guard !isEmpty else { return nil }
        return Dictionary(grouping: self, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key
    }
}
