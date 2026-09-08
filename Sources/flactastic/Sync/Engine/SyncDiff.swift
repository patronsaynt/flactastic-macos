import Foundation

/// Works out what a sync run would actually do.
///
/// Always computed by the side that will **receive** the data, from its own
/// manifest and the sender's. That placement is deliberate: the receiver is the
/// one whose files are at risk, so it is the one that decides what counts as a
/// conflict, and it recomputes the plan immediately before executing rather
/// than trusting the copy the sender echoes back.
///
/// Pure and synchronous — no I/O, no state — so every matching rule below is
/// directly testable against hand-built manifests.
enum SyncDiff {

    /// Builds the plan for receiving `incoming` into `local`.
    ///
    /// - Parameter direction: recorded on the plan for display, so the
    ///   confirmation sheet can say "from" or "to" correctly. It does not
    ///   change the computation — the receiver's arithmetic is the same either
    ///   way.
    static func plan(
        incoming: LibraryManifest,
        local: LibraryManifest,
        direction: SyncDirection,
        filter: SyncFilter = .unrestricted
    ) -> SyncPlan {
        let localByID = local.tracksByID
        let localByHash = local.tracksByContentHash

        var newTracks: [TrackManifestEntry] = []
        var conflicts: [TrackConflict] = []

        for entry in incoming.tracks {
            // Re-apply the filter on receipt. The sender is supposed to have
            // done this already; a peer that ignores the agreed filter is
            // buggy or hostile, and either way must not be able to push files
            // the user excluded.
            guard filter.allows(format: entry.format, artistKey: nil, fileSize: entry.fileSize) else {
                continue
            }

            if let existing = localByID[entry.trackID] {
                // Same identity. Only the tags can differ — if the audio itself
                // differs, that is still the same track as far as the user's
                // library is concerned, and the incoming copy wins.
                if entry.contentHash != existing.contentHash || entry.tagFingerprint != existing.tagFingerprint {
                    conflicts.append(TrackConflict(
                        incoming: entry,
                        existing: existing,
                        differingFields: differingFields(incoming: entry, existing: existing)
                    ))
                }
                continue
            }

            if localByHash[entry.contentHash] != nil {
                // Byte-identical file under a different ID — the xattr was
                // stripped somewhere (a FAT volume, a zip, a cloud provider) or
                // the two libraries imported the same file separately. Nothing
                // to transfer; the receiver adopts the sender's ID afterwards
                // so the next run matches on identity instead.
                continue
            }

            newTracks.append(entry)
        }

        // Playlists.
        let localPlaylists = local.playlistsByID
        var newPlaylists: [PlaylistManifestEntry] = []
        var playlistConflicts: [PlaylistConflict] = []

        for entry in incoming.playlists {
            guard filter.allows(playlistID: entry.id) else { continue }
            guard let existing = localPlaylists[entry.id] else {
                newPlaylists.append(entry)
                continue
            }
            if existing.contentHash != entry.contentHash || existing.name != entry.name {
                playlistConflicts.append(PlaylistConflict(incoming: entry, existing: existing))
            }
        }

        return SyncPlan(
            direction: direction,
            newTracks: newTracks.sorted { $0.relativePath < $1.relativePath },
            trackConflicts: conflicts.sorted { $0.incoming.relativePath < $1.incoming.relativePath },
            newPlaylists: newPlaylists.sorted { $0.name < $1.name },
            playlistConflicts: playlistConflicts.sorted { $0.incoming.name < $1.incoming.name }
        )
    }

    /// Human-readable summary of what differs, for the confirmation sheet.
    ///
    /// Purely presentational: the fingerprint comparison above has already
    /// decided *that* there is a conflict. This only answers "why is this row
    /// in the list?", so the user can judge whether they care.
    static func differingFields(incoming: TrackManifestEntry, existing: TrackManifestEntry) -> [String] {
        var fields: [String] = []
        if normalise(incoming.title) != normalise(existing.title)   { fields.append("Title") }
        if normalise(incoming.artist) != normalise(existing.artist) { fields.append("Artist") }
        if normalise(incoming.album) != normalise(existing.album)   { fields.append("Album") }
        if incoming.tagFingerprint != existing.tagFingerprint, fields.isEmpty {
            // Some other tag — genre, year, track number, compilation flags.
            // Naming them individually would mean shipping every tag in the
            // manifest purely to caption a row; "Other tags" is honest and
            // costs nothing.
            fields.append("Other tags")
        }
        if incoming.contentHash != existing.contentHash { fields.append("Audio file") }
        return fields
    }

    private static func normalise(_ value: String?) -> String {
        (value ?? "")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
