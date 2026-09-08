import Foundation
import Observation

@Observable
@MainActor
final class PlaylistStore {
    var playlists: [Playlist] = [] {
        didSet { playlistsByIDCache = nil }
    }

    /// Memoized id → playlist lookup, for views that resolve playlists per
    /// render (Home recents). Same discipline as `LibraryStore.albumsByID`.
    @ObservationIgnored private var playlistsByIDCache: [UUID: Playlist]?

    var playlistsByID: [UUID: Playlist] {
        // Read `playlists` unconditionally so @Observable registers the dependency.
        let current = playlists
        if let playlistsByIDCache { return playlistsByIDCache }
        let computed = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistsByIDCache = computed
        return computed
    }

    private var currentRootURL: URL?

    private var fileURL: URL? {
        guard let rootURL = currentRootURL else { return nil }
        let dir = rootURL.appendingPathComponent(".flactastic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlists.json")
    }

    // MARK: - Persistence

    func load(from libraryRootURL: URL) {
        currentRootURL = libraryRootURL

        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            playlists = try JSONDecoder().decode([Playlist].self, from: data)
        } catch {
            print("[PlaylistStore] Failed to load playlists: \(error)")
        }
    }

    func save() {
        guard let url = fileURL else {
            print("[PlaylistStore] Cannot save: no library root URL set")
            return
        }
        do {
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[PlaylistStore] Failed to save playlists: \(error)")
        }
    }

    // MARK: - Sync

    /// Inserts or replaces a playlist that arrived from a paired device.
    ///
    /// Matched on `id`, so a playlist that has travelled between devices stays
    /// one playlist instead of accumulating a copy per sync. A replacement is
    /// wholesale — the user was shown the conflict and approved the overwrite
    /// before any of this ran, so merging here would contradict what they
    /// agreed to.
    func upsertFromSync(_ playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
        } else {
            playlists.append(playlist)
        }
        save()
    }

    // MARK: - CRUD

    @discardableResult
    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        save()
        return playlist
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func renamePlaylist(id: UUID, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        save()
    }

    /// Updates editable playlist metadata (name, description, custom cover image).
    /// Pass `nil` for `customArtwork` to clear the cover.
    func updatePlaylistMetadata(
        id: UUID,
        name: String,
        description: String?,
        customArtwork: Data?
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = name
        playlists[index].description = description
        playlists[index].customArtwork = customArtwork
        save()
    }

    // MARK: - Track operations

    func addTracks(
        _ tracks: [Track],
        to playlistID: UUID,
        relativeTo rootURL: URL?,
        skipDuplicates: Bool = false
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              let rootURL else { return }

        let rootPath = rootURL.path

        // Prefer trackID-based duplicate detection (rename-safe) and fall back
        // to relative-path matching for legacy entries that lack a trackID.
        let existingByTrackID: Set<UUID> = skipDuplicates
            ? Set(playlists[index].entries.compactMap { $0.trackID })
            : []
        let existingByPath: Set<String> = skipDuplicates
            ? Set(playlists[index].entries.filter { $0.trackID == nil }.map { $0.relativePath })
            : []

        for track in tracks {
            let trackPath = track.url.path
            guard trackPath.hasPrefix(rootPath) else { continue }
            let relative = String(trackPath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            if skipDuplicates {
                if existingByTrackID.contains(track.id) { continue }
                if existingByPath.contains(relative) { continue }
            }
            playlists[index].entries.append(PlaylistEntry(trackID: track.id, relativePath: relative))
        }
        save()
    }

    /// Appends entries directly by relative path, preserving the order given.
    /// Used by the Spotify playlist rebuild flow, which knows each downloaded
    /// file's path but may not yet have a resolved library `Track` (the rescan
    /// can be in flight). Pass a `trackID` when known (e.g. a duplicate that
    /// matched an existing library track); pass `nil` for fresh downloads and
    /// `resolvedTracks` will stamp the id lazily on first resolution.
    ///
    /// `relativePaths` and `trackIDs` must be the same length and aligned.
    func appendEntries(relativePaths: [String], trackIDs: [UUID?], to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              relativePaths.count == trackIDs.count else { return }
        for (path, tid) in zip(relativePaths, trackIDs) {
            playlists[index].entries.append(PlaylistEntry(trackID: tid, relativePath: path))
        }
        save()
    }

    /// Counts how many of the given tracks already exist in the playlist.
    /// Prefers `trackID` matching (rename-safe) and falls back to relative-path
    /// matching for legacy entries that pre-date trackID persistence.
    func duplicateCount(of tracks: [Track], in playlistID: UUID, relativeTo rootURL: URL?) -> Int {
        guard let playlist = playlists.first(where: { $0.id == playlistID }),
              let rootURL else { return 0 }
        let rootPath = rootURL.path
        let existingByTrackID = Set(playlist.entries.compactMap { $0.trackID })
        let existingByPath    = Set(playlist.entries.filter { $0.trackID == nil }.map { $0.relativePath })
        var count = 0
        for track in tracks {
            if existingByTrackID.contains(track.id) { count += 1; continue }
            let trackPath = track.url.path
            guard trackPath.hasPrefix(rootPath) else { continue }
            let relative = String(trackPath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            if existingByPath.contains(relative) { count += 1 }
        }
        return count
    }

    func removeEntries(at offsets: IndexSet, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].entries.remove(atOffsets: offsets)
        save()
    }

    func removeEntries(ids: Set<UUID>, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Move the entry identified by `sourceID` to immediately before the entry
    /// identified by `destinationID`. Used by drag-and-drop reordering in the
    /// playlist detail view.
    func moveEntry(id sourceID: UUID, before destinationID: UUID, in playlistID: UUID) {
        guard let pIdx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var entries = playlists[pIdx].entries
        guard let srcIdx = entries.firstIndex(where: { $0.id == sourceID }),
              let dstIdx = entries.firstIndex(where: { $0.id == destinationID }),
              srcIdx != dstIdx else { return }
        let item = entries.remove(at: srcIdx)
        let insertIdx = srcIdx < dstIdx ? dstIdx - 1 : dstIdx
        entries.insert(item, at: insertIdx)
        playlists[pIdx].entries = entries
        save()
    }

    // MARK: - Resolution

    /// Resolves playlist entries to live Track objects from the library.
    ///
    /// **Fast path:** entries with a `trackID` are resolved by UUID — immune to
    /// file moves and renames.
    ///
    /// **Migration path:** entries without a `trackID` (written before this
    /// feature was introduced) fall back to relative-path resolution. When a
    /// match is found this way, the entry's `trackID` is stamped in-place so
    /// future resolutions use the fast path.
    func resolvedTracks(for playlist: Playlist, in library: LibraryStore) -> [Track] {
        guard let rootURL = library.rootURL,
              let pi = playlists.firstIndex(where: { $0.id == playlist.id }) else { return [] }

        let byID   = Dictionary(library.tracks.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(library.tracks.map { ($0.url.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        var needsSave = false
        var result: [Track] = []

        for j in playlists[pi].entries.indices {
            let entry = playlists[pi].entries[j]

            // Fast path: stable trackID.
            if let tid = entry.trackID, let track = byID[tid] {
                result.append(track)
                continue
            }

            // Migration fallback: resolve by absolute path and stamp trackID.
            let absolutePath = rootURL.appendingPathComponent(entry.relativePath).path
            if let track = byPath[absolutePath] {
                result.append(track)
                playlists[pi].entries[j].trackID = track.id
                needsSave = true
            }
            // Dangling entries (no match by ID or path) are silently skipped;
            // reconcile() handles their removal on the next scan.
        }

        if needsSave { save() }
        return result
    }

    // MARK: - Reconciliation

    /// Removes entries from all playlists whose tracks no longer exist in the
    /// library. Uses `trackID` for entries that have one (rename-safe), and
    /// falls back to absolute-path matching for legacy entries.
    func reconcile(with library: LibraryStore) {
        guard let rootURL = library.rootURL else { return }

        let libraryIDs   = Set(library.tracks.map { $0.id })
        let libraryPaths = Set(library.tracks.map { $0.url.path })
        var changed = false

        for i in playlists.indices {
            let before = playlists[i].entries.count
            playlists[i].entries.removeAll { entry in
                if let tid = entry.trackID { return !libraryIDs.contains(tid) }
                let absolutePath = rootURL.appendingPathComponent(entry.relativePath).path
                return !libraryPaths.contains(absolutePath)
            }
            if playlists[i].entries.count != before { changed = true }
        }

        if changed { save() }
    }
}
