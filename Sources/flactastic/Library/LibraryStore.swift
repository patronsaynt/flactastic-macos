import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class LibraryStore {
    enum ScanState: Equatable {
        case idle
        case scanning
        case refreshing
        case done(count: Int)
        case failed(String)
    }

    var rootURL: URL?
    var tracks: [Track] = [] {
        didSet {
            albumsCache = nil
            albumsByIDCache = nil
            tracksRevision &+= 1
        }
    }
    /// Bumped on every `tracks` assignment. Views should observe this with
    /// `.onChange` rather than `library.tracks` itself: `onChange` compares
    /// old vs new with `==`, and `Track`'s synthesized equality memcmps each
    /// track's embedded artwork. Every equal prefix of the array — or the
    /// whole thing, for passes like `deduplicateArtworkStorage` that change
    /// storage but not values — gets byte-compared on the main thread.
    private(set) var tracksRevision: Int = 0
    var scanState: ScanState = .idle
    /// Flips to `true` once the app's initial library load resolves (either a
    /// successful scan, a failure, or a confirmed no-op when there's nothing
    /// to scan). The UI gates its first paint on this so albums/tracks don't
    /// visibly populate during startup. Only the *first* resolution sets it;
    /// later manual refreshes do not reset it.
    var hasCompletedInitialLoad: Bool = false

    /// Ids that have already played their Collection-grid/list entrance
    /// (`riseFadeIn`) animation at least once this run. Deliberately kept
    /// here rather than as local `@State` on `CollectionView`/
    /// `ArtistsCollectionView`/`AllTracksView`: `ContentView` remounts each
    /// tab's content via `.id(router.selectedTab)` on every switch, which
    /// would reset local `@State` and replay every cell's fade-in each time
    /// you navigate away and back. Living on this long-lived store means an
    /// item only ever animates in once per app launch, no matter how many
    /// times its view is torn down and rebuilt.
    /// `@ObservationIgnored`: these are written from every cell's `.onAppear`
    /// while scrolling, and no view renders differently when membership
    /// changes — `riseFadeIn` reads the value once at cell init via a Binding
    /// getter. Observing them made each newly revealed cell invalidate the
    /// entire grid/list container mid-scroll.
    @ObservationIgnored var revealedAlbumIDs:  Set<String> = []
    @ObservationIgnored var revealedArtistIDs: Set<String> = []
    @ObservationIgnored var revealedTrackIDs:  Set<UUID> = []

    /// Per-album artwork cache. Keyed by album ID (artist|name). A key's
    /// *presence* means the album has been seeded; the value may be nil when
    /// the album genuinely has no artwork. Only written by:
    ///   • `seedAlbumArtworkCache()` — after scans and imports
    ///   • `invalidateAlbumArtwork(albumID:)` — called by the album editor
    /// Track-level edits (`updateTrack`) deliberately never touch this, so
    /// setting per-track artwork does not bleed into the album cover display.
    private var albumArtworkCache: [String: Data?] = [:] {
        didSet {
            albumsCache = nil
            albumsByIDCache = nil
        }
    }

    /// Memoized result of the `albums` grouping below. Grouping + sorting the
    /// whole track list is O(n log n) and `albums` is read from many view
    /// bodies (Collection grid, artist pages, detail views), so recomputing on
    /// every access makes scrolling visibly janky on large libraries.
    /// Invalidated whenever either input (`tracks`, `albumArtworkCache`)
    /// changes. `@ObservationIgnored` so filling the cache from within the
    /// getter doesn't trigger a spurious observation cycle.
    @ObservationIgnored private var albumsCache: [Album]?

    var albums: [Album] {
        // Read `tracks` unconditionally (not just on cache miss) so
        // @Observable still registers the dependency and views re-render
        // when the library changes.
        let currentTracks = tracks
        if let albumsCache { return albumsCache }
        let computed = Self.buildAlbums(from: currentTracks, artworkCache: albumArtworkCache)
        albumsCache = computed
        return computed
    }

    /// Memoized id → album lookup over `albums`, for views that resolve an
    /// album per render (detail views, Home tiles). Same invalidation
    /// discipline as `albumsCache`. Duplicate keys keep the first album,
    /// matching what a linear `first(where:)` scan would find.
    @ObservationIgnored private var albumsByIDCache: [String: Album]?

    var albumsByID: [String: Album] {
        let current = albums
        if let albumsByIDCache { return albumsByIDCache }
        let computed = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumsByIDCache = computed
        return computed
    }

    private static func buildAlbums(from tracks: [Track], artworkCache: [String: Data?]) -> [Album] {
        // Pass 1: group by normalized album name.
        let byName = Dictionary(grouping: tracks) {
            ($0.album ?? "Unknown Album").lowercased()
        }

        var result: [Album] = []

        for (_, nameGroup) in byName {
            // Pass 2: subdivide by albumArtist only when at least one track has it set.
            // This lets tracks with the same album name but different `artist` tags (and
            // no albumArtist) merge into one compilation instead of splitting.
            let hasAlbumArtist = nameGroup.contains(where: { $0.albumArtist != nil })

            let subgroups: [[Track]]
            if hasAlbumArtist {
                let sub = Dictionary(grouping: nameGroup) { $0.albumArtist ?? "Unknown Artist" }
                subgroups = Array(sub.values)
            } else {
                subgroups = [nameGroup]
            }

            for group in subgroups {
                let sorted = group.sorted { ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max) }
                let aa = sorted.first(where: { $0.albumArtist != nil })?.albumArtist
                // Compare lead credits, not raw tags: one track reading
                // "Deadmau5 ; Rob Swire" against nine reading "Deadmau5" is a
                // single-artist album with a guest, not a compilation. Counting
                // the raw strings made it read as "Various Artists".
                let distinct = Set(sorted.compactMap(\.artist).map(ArtistResolver.primaryCredit))
                let displayArtist: String?
                if let aa { displayArtist = aa }
                else if distinct.count > 1 { displayArtist = "Various Artists" }
                else { displayArtist = distinct.first }

                let key = "\(aa ?? displayArtist ?? "Unknown Artist")|\(sorted.first?.album ?? "Unknown Album")"
                result.append(Album(
                    id: key,
                    name: sorted.first?.album ?? "Unknown Album",
                    artist: displayArtist,
                    albumArtist: aa,
                    year: sorted.first?.year,
                    genre: sorted.first?.genre,
                    secondaryGenres: sorted.first?.secondaryGenres ?? [],
                    artwork: artworkCache[key] ?? Self.dominantArtwork(in: sorted),
                    tracks: sorted
                ))
            }
        }

        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns the artwork shared by the most tracks in a group.
    /// Ties are broken by first appearance, so a single outlier track with a
    /// unique cover (e.g. a single artwork set on one track) does not replace
    /// the artwork that represents the album as a whole.
    ///
    /// Distinctness is judged by `ArtworkImageCache.contentID` (byte count +
    /// sampled bytes) instead of hashing/equating the raw multi-MB blobs —
    /// this runs on every `albums` rebuild, and blob-keyed dictionaries were
    /// a measurable part of that cost. Same collision tradeoff the thumbnail
    /// cache already makes.
    private static func dominantArtwork(in tracks: [Track]) -> Data? {
        var counts: [String: Int] = [:]
        var firstData: [String: Data] = [:]
        var firstSeen: [String: Int] = [:] // insertion order for tie-breaking
        var index = 0
        for track in tracks {
            guard let art = track.artwork else { continue }
            let key = ArtworkImageCache.contentID(for: art)
            if counts[key] == nil {
                firstSeen[key] = index
                firstData[key] = art
            }
            counts[key, default: 0] += 1
            index += 1
        }
        guard !counts.isEmpty else { return nil }
        let best = counts.max {
            let (a, ca) = $0; let (b, cb) = $1
            if ca != cb { return ca < cb }           // prefer higher count
            return (firstSeen[a] ?? 0) > (firstSeen[b] ?? 0) // earlier = wins tie
        }
        return best.flatMap { firstData[$0.key] }
    }

    private let scanner = LibraryScanner()
    private var scanTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    /// Persists relativePath → UUID so Track identities survive restarts.
    /// Loaded in `openFolder` and consulted during every scan.
    private(set) var trackIDStore = TrackIDStore()

    func album(for track: Track) -> Album? {
        albums.first { $0.tracks.contains { $0.id == track.id } }
    }

    /// Seeds `albumArtworkCache` for any album not yet present. Safe to call
    /// repeatedly — existing entries are never overwritten, so artwork locked in
    /// by a prior seed or by the album editor is preserved through rescans.
    func seedAlbumArtworkCache() {
        for album in albums {
            guard albumArtworkCache[album.id] == nil else { continue }
            albumArtworkCache[album.id] = album.artwork
        }
    }

    /// Decodes and disk-/memory-caches every album's grid, list-row, and
    /// detail-header thumbnail sizes up front, off the main thread, right
    /// after the library finishes loading. Without this, the first scroll
    /// through the Collection grid pays decode cost live, one cell at a
    /// time, which is visible as stutter even with `ArtworkImageCache` in
    /// place — the cache only helps once something has populated it.
    /// Albums are warmed in display order (alphabetical, matching the
    /// default Collection sort) so the albums the user sees first finish
    /// warming first.
    func prewarmArtworkCache() {
        let snapshot = albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Task.detached(priority: .utility) {
            for album in snapshot {
                guard let data = album.artwork else { continue }
                let id = "album:\(album.id)"
                for size: CGFloat in [180, 48, 200] {
                    ArtworkImageCache.shared.prewarm(data: data, id: id, pointSize: size)
                }
                // Track rows (36pt) key their thumbnails by artwork *content*,
                // so one entry per distinct cover warms every row sharing it.
                ArtworkImageCache.shared.prewarm(
                    data: data,
                    id: ArtworkImageCache.contentID(for: data),
                    pointSize: 36
                )
            }
        }
    }

    /// Collapses duplicate artwork allocations so identical embedded covers
    /// share one CoW `Data` buffer. Every track parses its picture into its
    /// own allocation, so a 12-track album holds 12 identical multi-MB
    /// buffers — across a large library that's gigabytes of redundant RAM.
    /// After this pass, memory is O(distinct covers) instead of O(tracks),
    /// and every consumer (`TrackRow`, Now Playing, editors) keeps working
    /// unchanged because the bytes are identical — only the storage is shared.
    ///
    /// Duplicates are detected by `ArtworkImageCache.contentID`, avoiding
    /// full-blob hashing/comparison; same collision tradeoff as the
    /// thumbnail cache.
    private func deduplicateArtworkStorage() {
        var canonicalByContent: [String: Data] = [:]
        var updated = tracks
        var changed = false
        for i in updated.indices {
            guard let art = updated[i].artwork else { continue }
            let key = ArtworkImageCache.contentID(for: art)
            if let canon = canonicalByContent[key] {
                updated[i].artwork = canon
                changed = true
            } else {
                canonicalByContent[key] = art
            }
        }
        if changed { tracks = updated }
    }

    /// Snapshot the fully-parsed library and rewrite the metadata sidecar,
    /// off the main actor, once per completed scan batch. Must run while
    /// tracks still hold their parsed artwork (before any artwork
    /// offloading) so `hasArtwork` is recorded correctly.
    private func persistMetadataCache() {
        guard let rootURL else { return }
        let snapshot = tracks
        Task.detached(priority: .utility) {
            TrackMetadataCache.rebuild(from: snapshot, rootURL: rootURL)
        }
    }

    /// Called by the album editor after saving. Clears the cached artwork for
    /// `albumID` so the next `albums` access recomputes it from the freshly-
    /// written track files (dominant artwork = the one just saved to all tracks).
    func invalidateAlbumArtwork(albumID: String) {
        albumArtworkCache.removeValue(forKey: albumID)
        seedAlbumArtworkCache()
        ArtworkImageCache.shared.invalidate(id: "album:\(albumID)")
    }

    /// Replaces the stored `Track` matching `id` with `updated`.
    /// Because `albums` is a computed property, callers in album-detail views
    /// and the collection grid will automatically see the new metadata.
    func updateTrack(id: UUID, with updated: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i] = updated
    }

    /// Applies many track updates atomically in a single `tracks` assignment.
    /// Prefer this over per-track `updateTrack` when renaming fields that affect
    /// album grouping (artist/album name): a piecemeal update would briefly
    /// split the album across two grouping keys and cause detail views to
    /// render "Album not found" mid-operation.
    func replaceTracks(_ updated: [Track]) {
        guard !updated.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        tracks = tracks.map { byID[$0.id] ?? $0 }
    }

    /// Appends tracks that entered the library via the Import menu (rather
    /// than a folder scan). Deduplicates by URL — if the same file path is
    /// already known, the existing entry wins so its UUID (and any queue/
    /// playlist membership) stays stable.
    func addImportedTracks(_ imported: [Track]) {
        guard !imported.isEmpty else { return }
        let existing = Set(tracks.map { $0.url })
        var fresh = imported.filter { !existing.contains($0.url) }
        guard !fresh.isEmpty else { return }
        // Assign stable IDs to newly-imported tracks so playlist membership
        // survives the next app restart.
        if let url = rootURL {
            fresh = applyStableIDs(to: fresh, rootURL: url)
            trackIDStore.save()
        }
        tracks = (tracks + fresh).sortedForLibrary()
        normaliseArtistTags()
        seedAlbumArtworkCache()
    }

    /// Removes tracks from the library and moves their files to the Trash.
    /// Tracks whose file couldn't be trashed stay in the library; returns
    /// the number that failed.
    @discardableResult
    func removeTracks(_ toRemove: [Track]) -> Int {
        guard !toRemove.isEmpty else { return 0 }
        var removedIDs = Set<UUID>()
        var failures = 0
        for track in toRemove {
            do {
                if FileManager.default.fileExists(atPath: track.url.path) {
                    try FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
                }
                removedIDs.insert(track.id)
            } catch {
                failures += 1
            }
        }
        guard !removedIDs.isEmpty else { return failures }
        tracks = tracks.filter { !removedIDs.contains($0.id) }
        seedAlbumArtworkCache()
        persistMetadataCache()
        return failures
    }

    func openFolder(_ url: URL) {
        scanTask?.cancel()
        metadataTask?.cancel()
        rootURL = url
        scanState = .scanning
        tracks = []

        // Load the sidecar before scanning so assign() returns persisted UUIDs.
        trackIDStore.load(from: url)

        scanTask = Task { [scanner] in
            do {
                let cheap = try await scanner.scan(root: url)
                if Task.isCancelled { return }
                // Rewrite ephemeral UUIDs → stable IDs from the sidecar.
                let stable = self.applyStableIDs(to: cheap, rootURL: url)
                self.trackIDStore.save()
                self.tracks = stable
                self.scanState = .done(count: stable.count)
                // Note: we deliberately do NOT flip `hasCompletedInitialLoad`
                // here. The cheap scan gives us URLs but no metadata, so
                // album grouping would churn as artist/album tags stream in.
                // The flag flips once `startMetadataLoad` finishes.
                self.startMetadataLoad()
            } catch {
                if Task.isCancelled { return }
                self.scanState = .failed(String(describing: error))
                self.hasCompletedInitialLoad = true
            }
        }
    }

    func refreshLibrary() {
        guard let url = rootURL else { return }
        guard scanState != .scanning else { return }

        scanTask?.cancel()
        metadataTask?.cancel()
        scanState = .refreshing

        scanTask = Task { [scanner] in
            do {
                let scanned = try await scanner.scan(root: url)
                if Task.isCancelled { return }

                let existingByURL = Dictionary(
                    self.tracks.map { ($0.url, $0) },
                    uniquingKeysWith: { _, last in last }
                )

                // Assign stable IDs only to genuinely new files — existing
                // in-memory tracks already carry their stable UUID from the
                // last openFolder/refresh call.
                let rawNewStubs = scanned.filter { existingByURL[$0.url] == nil }
                let stableNewStubs = self.applyStableIDs(to: rawNewStubs, rootURL: url)
                if !stableNewStubs.isEmpty { self.trackIDStore.save() }

                let stableByURL = Dictionary(
                    stableNewStubs.map { ($0.url, $0) },
                    uniquingKeysWith: { _, last in last }
                )
                let merged: [Track] = scanned.map { stub in
                    existingByURL[stub.url] ?? stableByURL[stub.url] ?? stub
                }

                self.tracks = merged
                self.scanState = .done(count: merged.count)

                if !stableNewStubs.isEmpty {
                    self.startMetadataLoadForTracks(stableNewStubs)
                }
            } catch {
                if Task.isCancelled { return }
                self.scanState = .failed(String(describing: error))
            }
        }
    }

    private func startMetadataLoadForTracks(_ newTracks: [Track]) {
        let snapshot = newTracks
        metadataTask = Task { [scanner] in
            // New files are usually cache misses, but the sidecar still
            // covers files that were moved/renamed within the library.
            let rootPath = self.rootURL?.path
            let cachedEntries: [String: TrackMetadataCacheEntry]
            if let rootURL = self.rootURL {
                cachedEntries = await Task.detached(priority: .userInitiated) {
                    TrackMetadataCache.load(rootURL: rootURL)
                }.value
            } else {
                cachedEntries = [:]
            }

            await withTaskGroup(of: Track.self) { group in
                let maxConcurrent = 8
                var index = 0
                var inFlight = 0

                func submit(_ t: Track) {
                    let entry = rootPath.flatMap {
                        cachedEntries[TrackMetadataCache.relativePath(for: t.url, rootPath: $0)]
                    }
                    group.addTask { [scanner] in await scanner.loadMetadata(for: t, cached: entry) }
                }

                while index < snapshot.count && inFlight < maxConcurrent {
                    submit(snapshot[index]); index += 1; inFlight += 1
                }
                // Batch publication — see the matching comment in
                // `startMetadataLoad` for why per-file `tracks` mutation is
                // quadratic during scans.
                var pending: [Track] = []
                var lastFlush = ContinuousClock.now
                // Explicit @MainActor: local funcs don't inherit the enclosing
                // closure's actor isolation. Called only from this main-actor task.
                @MainActor func flush() {
                    guard !pending.isEmpty else { return }
                    self.replaceTracks(pending)
                    pending.removeAll(keepingCapacity: true)
                    lastFlush = .now
                }
                while let updated = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    pending.append(updated)
                    if pending.count >= 24 || lastFlush.duration(to: .now) >= .milliseconds(250) {
                        flush()
                    }
                    if index < snapshot.count { submit(snapshot[index]); index += 1 }
                }
                if !Task.isCancelled {
                    flush()
                    self.tracks = self.tracks.sortedForLibrary()
                    self.normaliseArtistTags()
                    self.deduplicateArtworkStorage()
                    self.seedAlbumArtworkCache()
                    self.prewarmArtworkCache()
                    self.persistMetadataCache()
                }
            }
        }
    }

    /// Rewrites each track's `id` to the stable UUID from `trackIDStore`,
    /// using the track's relative path as the lookup key.  New paths are
    /// assigned a fresh UUID and recorded.
    ///
    /// **Does not save** — callers must call `trackIDStore.save()` once after
    /// the full batch to avoid per-track disk writes.
    @discardableResult
    private func applyStableIDs(to tracks: [Track], rootURL: URL) -> [Track] {
        let rootPath = rootURL.path
        return tracks.map { track in
            guard track.url.path.hasPrefix(rootPath) else { return track }
            let rel = String(track.url.path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            let stableID = trackIDStore.assign(fileURL: track.url, relativePath: rel)
            guard stableID != track.id else { return track }
            return Track(
                id: stableID,
                url: track.url,
                title: track.title,
                artist: track.artist,
                albumArtist: track.albumArtist,
                album: track.album,
                trackNumber: track.trackNumber,
                duration: track.duration,
                artwork: track.artwork,
                fileFormat: track.fileFormat,
                sampleRate: track.sampleRate,
                bitDepth: track.bitDepth,
                genre: track.genre,
                year: track.year,
                isCompilation: track.isCompilation,
                dateAdded: track.dateAdded
            )
        }
    }

    private func startMetadataLoad() {
        let snapshot = tracks
        metadataTask = Task { [scanner] in
            // Sidecar metadata cache: unchanged files (validated by size +
            // mtime) hydrate from it instead of paying the full TagLib +
            // AVFoundation parse. Loaded off-main; an empty dictionary just
            // means every file takes the full parse path.
            let rootPath = self.rootURL?.path
            let cachedEntries: [String: TrackMetadataCacheEntry]
            if let rootURL = self.rootURL {
                cachedEntries = await Task.detached(priority: .userInitiated) {
                    TrackMetadataCache.load(rootURL: rootURL)
                }.value
            } else {
                cachedEntries = [:]
            }

            // Cap concurrency at 8 so we don't thrash the disk.
            await withTaskGroup(of: (Int, Track).self) { group in
                let maxConcurrent = 8
                var index = 0
                var inFlight = 0

                func submit(_ i: Int, _ t: Track) {
                    let entry = rootPath.flatMap {
                        cachedEntries[TrackMetadataCache.relativePath(for: t.url, rootPath: $0)]
                    }
                    group.addTask { [scanner] in
                        let updated = await scanner.loadMetadata(for: t, cached: entry)
                        return (i, updated)
                    }
                }

                while index < snapshot.count && inFlight < maxConcurrent {
                    submit(index, snapshot[index])
                    index += 1
                    inFlight += 1
                }

                // Buffer finished tracks and publish in batches. Every `tracks`
                // mutation invalidates `albumsCache`, so per-file assignment
                // makes any view reading `albums` re-group the whole library
                // once per file — O(n²) over a large scan. Batching keeps the
                // UI populating progressively at a fraction of the cost.
                var pending: [(Int, Track)] = []
                var lastFlush = ContinuousClock.now
                // Explicit @MainActor: local funcs don't inherit the enclosing
                // closure's actor isolation. Called only from this main-actor task.
                @MainActor func flush() {
                    guard !pending.isEmpty else { return }
                    var current = self.tracks
                    for (i, updated) in pending {
                        if i < current.count, current[i].id == updated.id {
                            current[i] = updated
                        }
                    }
                    self.tracks = current
                    pending.removeAll(keepingCapacity: true)
                    lastFlush = .now
                }

                while let (i, updated) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    pending.append((i, updated))
                    if pending.count >= 24 || lastFlush.duration(to: .now) >= .milliseconds(250) {
                        flush()
                    }
                    if index < snapshot.count {
                        submit(index, snapshot[index])
                        index += 1
                    }
                }

                // Re-sort after metadata is loaded so albums group properly.
                if !Task.isCancelled {
                    flush()
                    self.tracks = self.tracks.sortedForLibrary()

                    // Reveal the UI as soon as the grid is stable-sorted —
                    // i.e. the moment the Collection is genuinely populated.
                    // The two refinements below (tag normalisation + artwork
                    // cache seeding) are non-essential to first paint and each
                    // walks the whole library, so they used to add a visible
                    // tail to the loading cover even though the data was ready.
                    // We now run them *after* the flip so the home page appears
                    // in lockstep with the Collection being done. Deliberately
                    // not wrapped in `withAnimation`: flipping it inside one
                    // let SwiftUI re-render during the property's `willSet`,
                    // read the stale `false`, and miss the change entirely.
                    // ContentView animates the cover's fade itself.
                    if !self.hasCompletedInitialLoad {
                        self.hasCompletedInitialLoad = true
                    }

                    // Run the whole-library refinements on a *later* runloop
                    // turn. Each one re-walks the library (and recomputes the
                    // expensive `albums`), and `normaliseArtistTags` reassigns
                    // `tracks`. Doing that synchronously in the same tick as the
                    // flag flip starves SwiftUI's cover-removal render — most
                    // visibly on the heavier Home tab, where the loading cover
                    // would stay stuck until the next navigation. Yielding first
                    // lets the cover fade out cleanly before this work begins.
                    Task { @MainActor in
                        // A bare `Task {}` enqueued from this main-actor
                        // continuation can drain before SwiftUI commits the
                        // flag flip, so actually wait out the cover's fade.
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        self.normaliseArtistTags()
                        // Dedup before seeding so the album cache and albums
                        // reference the shared canonical buffers.
                        self.deduplicateArtworkStorage()
                        self.seedAlbumArtworkCache()
                        self.prewarmArtworkCache()
                        self.persistMetadataCache()
                    }
                }
            }
        }
    }
}
