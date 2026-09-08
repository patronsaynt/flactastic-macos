import Foundation

/// Turns this device's library into a `LibraryManifest` to offer a peer.
///
/// An `actor` because it does the heaviest disk work in the feature — a full
/// pass of SHA-256 over every file the filter admits — and none of that belongs
/// on the main actor. Progress is reported so the Sync screen can show
/// something truthful during what may be minutes of hashing on a first run.
///
/// The filter is applied **here**, before hashing, so excluded files are never
/// read at all. That is a privacy property as much as a performance one: a
/// track the user excluded is never opened, never hashed, and never described
/// to the peer in any form.
actor ManifestBuilder {

    enum BuildError: Error, CustomStringConvertible {
        case noLibraryRoot

        var description: String {
            switch self {
            case .noLibraryRoot: return "No music folder is open."
            }
        }
    }

    /// Builds the manifest and refreshes the hash sidecar.
    ///
    /// - Parameter progress: fraction in 0...1, called on an arbitrary
    ///   executor. Callers hop to the main actor themselves.
    func build(
        tracks: [Track],
        playlists: [Playlist],
        rootURL: URL,
        deviceID: UUID,
        filter: SyncFilter,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> LibraryManifest {
        let rootPath = rootURL.path
        var cache = ContentHashCache.load(rootURL: rootURL)
        let fileManager = FileManager.default

        // Admitted before any file is opened.
        let candidates = tracks.filter { track in
            filter.allows(
                format: track.fileFormat,
                artistKey: Self.artistKey(for: track),
                fileSize: Self.fileSize(of: track.url, fileManager: fileManager) ?? 0
            )
        }

        var entries: [TrackManifestEntry] = []
        entries.reserveCapacity(candidates.count)
        var livePaths = Set<String>()

        for (index, track) in candidates.enumerated() {
            try Task.checkCancellation()

            guard track.url.path.hasPrefix(rootPath) else {
                // A track outside the library root cannot be described by a
                // relative path, so it cannot be synced. Files reach this state
                // through an interrupted move or an edited sidecar.
                continue
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: track.url.path),
                  let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
                  let mtime = attributes[.modificationDate] as? Date else {
                // Vanished between the scan and now. Skipping is right: the
                // alternative is offering a peer a file we cannot send.
                continue
            }
            guard fileSize <= SyncProtocol.maxFileBytes else { continue }

            let relativePath = TrackMetadataCache.relativePath(for: track.url, rootPath: rootPath)
            livePaths.insert(relativePath)

            let hash: String
            if let cached = cache.hash(forRelativePath: relativePath, fileSize: fileSize, mtime: mtime) {
                hash = cached
            } else {
                guard let computed = try? ContentHasher.hexDigest(ofFileAt: track.url) else { continue }
                hash = computed
                cache.store(hash: hash, forRelativePath: relativePath, fileSize: fileSize, mtime: mtime)
            }

            entries.append(TrackManifestEntry(
                trackID: track.id,
                relativePath: relativePath,
                fileSize: fileSize,
                contentHash: hash,
                format: track.fileFormat,
                tagFingerprint: TagFingerprint.compute(for: track),
                title: track.title,
                artist: track.artist,
                album: track.album
            ))

            progress(Double(index + 1) / Double(max(1, candidates.count)))
        }

        cache.prune(keeping: livePaths)
        cache.save(rootURL: rootURL)

        let playlistEntries = playlists
            .filter { filter.allows(playlistID: $0.id) }
            .map(Self.manifestEntry(for:))

        return LibraryManifest(deviceID: deviceID, tracks: entries, playlists: playlistEntries)
    }

    // MARK: - Helpers

    /// Album artist first, then track artist — the same precedence the
    /// Collection uses for grouping, so excluding an artist in the sync filter
    /// excludes the records the user actually sees under that name.
    nonisolated static func artistKey(for track: Track) -> String? {
        let raw = track.albumArtist ?? track.artist
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return ArtistResolver.key(for: raw)
    }

    nonisolated static func fileSize(of url: URL, fileManager: FileManager = .default) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value }
    }

    /// Hashes a playlist's ordered contents.
    ///
    /// Order is included because a reordered playlist is a genuinely different
    /// playlist to the person who reordered it. The entry's own UUID is *not*
    /// included: it is local bookkeeping for SwiftUI identity and differs
    /// between two devices holding the same playlist.
    nonisolated static func contentHash(for playlist: Playlist) -> String {
        let body = playlist.entries
            .map { "\($0.trackID?.uuidString ?? "-")|\($0.relativePath)" }
            .joined(separator: "\n")
        return ContentHasher.hexDigest(of: Data("\(playlist.name)\n\(body)".utf8))
    }

    nonisolated static func manifestEntry(for playlist: Playlist) -> PlaylistManifestEntry {
        PlaylistManifestEntry(
            id: playlist.id,
            name: playlist.name,
            dateCreated: playlist.dateCreated,
            entryCount: playlist.entries.count,
            contentHash: contentHash(for: playlist)
        )
    }
}
