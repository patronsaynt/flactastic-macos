import Foundation

extension LibraryStore {
    /// Build a resolver from the current track set. Cheap to call repeatedly,
    /// but callers in views should hoist it for the duration of a render pass.
    /// The resolver for the current library, cached until `tracks` changes.
    func makeArtistResolver() -> ArtistResolver {
        // Read the revision so callers in a view body still re-render when
        // the library changes, as they did when this rebuilt every time.
        _ = tracksRevision
        if let cached = artistResolverCache { return cached }
        let resolver = ArtistResolver(tracks: tracks)
        artistResolverCache = resolver
        return resolver
    }

    /// `allArtists` with the current resolver, cached until the library or
    /// the overrides (identified by `overridesRevision`) change.
    func cachedAllArtists(overrides: [String: ArtistOverride], overridesRevision: Int) -> [ArtistSummary] {
        _ = tracksRevision
        if let cached = artistSummariesCache, cached.overridesRevision == overridesRevision {
            return cached.summaries
        }
        let summaries = allArtists(resolver: makeArtistResolver(), overrides: overrides)
        artistSummariesCache = (overridesRevision, summaries)
        return summaries
    }

    /// Normalise multi-artist credit strings in-memory so collaboration tags
    /// imported from third-party tools surface as chips in the editor and
    /// produce per-artist links across the UI without the user having to
    /// edit each track. Safe by design: a string is rewritten only when
    /// *every* fragment maps to an artist already known to the library
    /// (canonical names with no separators of their own).
    ///
    /// Does NOT touch the source files — the rewrite is only on the
    /// in-memory `Track.artist` value. The user can persist via the editor.
    /// Iterates twice so freshly-confirmed names from the first pass help
    /// resolve borderline strings in the second.
    func normaliseArtistTags() {
        var working = tracks
        var didChange = false

        for _ in 0..<2 {
            let resolver = ArtistResolver(tracks: working)
            var passChanged = false
            for i in working.indices {
                guard let raw = working[i].artist, !raw.isEmpty else { continue }
                // Skip strings that already use the explicit delimiter.
                if ArtistResolver.explicitlySeparated(raw) != nil { continue }
                let pieces = resolver.split(raw)
                guard pieces.count > 1 else { continue }
                let joined = ArtistResolver.joinExplicit(pieces)
                if joined != raw {
                    working[i].artist = joined
                    passChanged = true
                }
            }
            if !passChanged { break }
            didChange = true
        }

        if didChange { tracks = working }
    }

    /// All artists in the library, with their albums / singles / appears-on
    /// buckets. Computed in a single pass over `albums`.
    /// Override `displayName(forKey:)` is consulted when provided.
    func allArtists(
        resolver: ArtistResolver,
        overrides: [String: ArtistOverride] = [:]
    ) -> [ArtistSummary] {
        struct Bucket {
            var displayName: String
            var albums: [Album] = []
            var singles: [Album] = []
            var appearsOn: [Album] = []
            var albumIDs = Set<String>()
            var appearsOnIDs = Set<String>()
            var trackCount: Int = 0
            var artworkSample: Data?
        }
        var buckets: [String: Bucket] = [:]

        let allAlbums = albums

        for album in allAlbums {
            // Compilations skip album-artist bucketing entirely: they don't
            // belong to any single artist's "own releases", but every track's
            // performer still picks up the album under "Appears On" below.
            let primarySource = album.albumArtist ?? album.artist
            let primaryKeys: [String] = album.isCompilation
                ? []
                : resolver.keys(forCredit: primarySource)
            let primaryKeySet = Set(primaryKeys)

            for key in primaryKeys {
                var bucket = buckets[key] ?? Bucket(
                    displayName: overrides[key]?.displayName?.nonEmpty
                        ?? resolver.displayName(forKey: key)
                )
                if !bucket.albumIDs.contains(album.id) {
                    if album.tracks.count >= 3 {
                        bucket.albums.append(album)
                    } else {
                        bucket.singles.append(album)
                    }
                    bucket.albumIDs.insert(album.id)
                }
                bucket.trackCount += album.tracks.count
                if bucket.artworkSample == nil { bucket.artworkSample = album.artwork }
                buckets[key] = bucket
            }

            // Guest credits: any per-track artist key not in the album's
            // primary set adds the album to that artist's "Appears On".
            for track in album.tracks {
                let trackKeys = resolver.keys(forCredit: track.artist)
                for key in trackKeys where !primaryKeySet.contains(key) {
                    var bucket = buckets[key] ?? Bucket(
                        displayName: overrides[key]?.displayName?.nonEmpty
                            ?? resolver.displayName(forKey: key)
                    )
                    if !bucket.albumIDs.contains(album.id),
                       !bucket.appearsOnIDs.contains(album.id) {
                        bucket.appearsOn.append(album)
                        bucket.appearsOnIDs.insert(album.id)
                    }
                    bucket.trackCount += 1
                    if bucket.artworkSample == nil { bucket.artworkSample = album.artwork }
                    buckets[key] = bucket
                }
            }
        }

        let summaries = buckets.map { (key, bucket) in
            ArtistSummary(
                id: key,
                displayName: bucket.displayName,
                albums: bucket.albums.sorted(by: Self.albumOrder),
                singles: bucket.singles.sorted(by: Self.albumOrder),
                appearsOn: bucket.appearsOn.sorted(by: Self.albumOrder),
                trackCount: bucket.trackCount,
                artworkSample: bucket.artworkSample
            )
        }
        return summaries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func artist(
        forKey key: String,
        resolver: ArtistResolver,
        overrides: [String: ArtistOverride] = [:]
    ) -> ArtistSummary? {
        // Only build the bucket for this key — cheaper than allArtists when
        // navigating into a single page.
        allArtists(resolver: resolver, overrides: overrides).first { $0.id == key }
    }

    private static func albumOrder(_ a: Album, _ b: Album) -> Bool {
        let ya = a.year ?? 0
        let yb = b.year ?? 0
        if ya != yb { return ya > yb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
