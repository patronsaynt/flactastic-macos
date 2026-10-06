import Foundation
import Observation

/// Rebuilds a public Spotify playlist into the local library + a matching
/// FLACtastic playlist.
///
/// For each track, in playlist order:
///   1. Skip if it's already in the library (reuse the existing file).
///   2. Download via the shared `DownloadCoordinator`. `LucidaWebProvider`
///      tries a matched non-Spotify equivalent first and only falls back to
///      the Spotify link itself (see `SourceMatchService`).
///   3. Append the track to the local playlist (or record a failure).
///
/// Progress and a final failure summary are published for the Download tab UI.
@Observable
@MainActor
final class PlaylistRebuildCoordinator {

    enum Phase: Sendable {
        case idle
        /// Downloading the playlist cover before track work begins.
        case fetchingArtwork
        case running(current: Int, total: Int)
        case finished(Summary)

        /// True whenever a rebuild is in progress or its summary is on screen.
        var isActive: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    struct TrackFailure: Sendable, Identifiable {
        let id = UUID()
        let index: Int          // 1-based position in the playlist
        let title: String
        let artist: String
        let reason: String
    }

    /// A track that was already in the library and reused rather than
    /// re-downloaded.
    struct ReusedTrack: Sendable, Identifiable {
        let id = UUID()
        let index: Int
        let title: String
        let artist: String
    }

    struct Summary: Sendable {
        let playlistName: String
        let total: Int
        let downloaded: Int
        let reused: [ReusedTrack]
        let failures: [TrackFailure]
        /// Tracks that were already present in the existing playlist and skipped entirely.
        let alreadyInPlaylist: Int
        /// True when this run resumed an existing playlist rather than creating a new one.
        let isResume: Bool
    }

    /// How many tracks to match + download at once. As soon as one finishes,
    /// the next track in the list starts — a sliding window rather than fixed
    /// batches — so the pipeline stays full without waiting on the slowest track
    /// in a batch.
    ///
    /// Kept deliberately low: a track's wall-clock time is dominated by Lucida's
    /// own server-side fetch/transcode (we just poll until it's done), not by
    /// our bandwidth, so extra concurrency doesn't speed up individual tracks —
    /// it only multiplies job-initiation pressure on Lucida's per-IP rate
    /// limiter. Smoothing initiation *cadence* (see `LucidaWebProvider`'s
    /// initiation throttle) matters far more than raising this number.
    static let maxConcurrent = 3

    /// Minimum spacing between launching new download tasks. Complements the
    /// global initiation throttle in `LucidaWebProvider`; staggering avoids
    /// firing the whole window at Lucida simultaneously.
    static let launchStagger: UInt64 = 750_000_000   // 0.75s

    /// How many times to retry a track whose every source failed *transiently*
    /// (Lucida busy / rate-limiting) before giving up. Permanent failures (no
    /// matching release, unsupported source) are not retried — see
    /// `isPermanentFailure`.
    static let maxDownloadAttempts = 3

    private(set) var phase: Phase = .idle
    private(set) var currentTrackTitle: String?

    private let downloads: DownloadCoordinator
    private let playlistStore: PlaylistStore
    private let library: LibraryStore
    private let lucidaProvider: LucidaWebProvider
    private let spotifyService: SpotifyPlaylistService
    private let urlSession: URLSession

    private var rebuildTask: Task<Void, Never>?

    init(
        downloads: DownloadCoordinator,
        playlistStore: PlaylistStore,
        library: LibraryStore,
        lucidaProvider: LucidaWebProvider,
        spotifyService: SpotifyPlaylistService = SpotifyPlaylistService(),
        urlSession: URLSession = .shared
    ) {
        self.downloads = downloads
        self.playlistStore = playlistStore
        self.library = library
        self.lucidaProvider = lucidaProvider
        self.spotifyService = spotifyService
        self.urlSession = urlSession
    }

    /// Resolve a public Spotify playlist URL via the no-auth embed preview
    /// (capped at 100 tracks). Used for the paste-a-link fallback when the
    /// user isn't connected — connect the Spotify account for full tracklists.
    func resolve(_ url: URL) async throws -> SpotifyPlaylistService.Result {
        try await spotifyService.resolve(url)
    }

    /// Resolve a playlist using a user OAuth bearer token — fetches the user's
    /// private and public playlists in full. The rebuild pipeline downstream is
    /// identical regardless of how the playlist was resolved.
    func resolve(
        _ url: URL,
        userToken: String
    ) async throws -> SpotifyPlaylistService.Result {
        try await spotifyService.resolve(url, userToken: userToken)
    }

    /// Resolve the user's Liked Songs into a `RemotePlaylist`, same pipeline
    /// as a real playlist from here on.
    func resolveLikedSongs(userToken: String) async throws -> SpotifyPlaylistService.Result {
        try await spotifyService.resolveLikedSongs(userToken: userToken)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        if case .fetchingArtwork = phase { return true }
        return false
    }

    // MARK: - Public API

    func rebuild(from playlist: RemotePlaylist, options: LucidaOptions) {
        guard !isRunning else { return }
        rebuildTask = Task { [weak self] in
            await self?.run(playlist: playlist, options: options)
        }
    }

    /// Cancel an in-progress rebuild. The in-flight download is torn down via
    /// `enqueueAndAwait`'s cancellation handler; tracks completed so far stay in
    /// the playlist.
    func cancel() {
        rebuildTask?.cancel()
    }

    /// Dismiss the finished summary card, returning the UI to idle.
    func dismissSummary() {
        if case .finished = phase {
            phase = .idle
            currentTrackTitle = nil
        }
    }

    // MARK: - Rebuild pipeline

    private func run(playlist: RemotePlaylist, options: LucidaOptions) async {
        guard let rootURL = library.rootURL else {
            phase = .finished(Summary(
                playlistName: playlist.title, total: playlist.tracks.count,
                downloaded: 0, reused: [], failures: [
                    TrackFailure(index: 0, title: playlist.title, artist: "",
                                 reason: "No music folder selected.")
                ], alreadyInPlaylist: 0, isResume: false
            ))
            return
        }

        // 1. Reuse an existing playlist with the same name (case-insensitive),
        //    or create a new one. This prevents duplicates when the user
        //    re-downloads a playlist they already have.
        phase = .fetchingArtwork
        let normalizedRemoteName = playlist.title
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existingPlaylist = playlistStore.playlists.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == normalizedRemoteName
        }
        let isResume = existingPlaylist != nil
        let target = existingPlaylist ?? playlistStore.createPlaylist(name: playlist.title)

        // Build lookup sets so processTrack can detect already-covered entries
        // in O(1) without holding a lock.
        let existingPaths  = Set(target.entries.map { $0.relativePath })
        let existingIDs    = Set(target.entries.compactMap { $0.trackID })

        let artwork = await fetchArtwork(playlist.coverArt)
        playlistStore.updatePlaylistMetadata(
            id: target.id,
            name: playlist.title,
            description: playlist.creator.map { "by \($0)" },
            customArtwork: artwork
        )

        // 2. Walk the tracklist with a sliding window: keep up to
        //    `maxConcurrent` tracks in flight and launch the next one the moment
        //    any finishes. Results arrive out of order, so we buffer them by
        //    position and flush to the playlist in strict playlist order.
        let tracks = playlist.tracks
        let total = tracks.count
        var downloaded = 0
        var reused: [ReusedTrack] = []
        var failures: [TrackFailure] = []
        var alreadyInPlaylist = 0
        var completed = 0

        currentTrackTitle = nil
        phase = .running(current: 0, total: total)

        // Applies a single track's result to the playlist + running tallies.
        func apply(_ result: TrackResult, at position: Int) {
            let track = tracks[position]
            switch result {
            case .reused(let rel, let tid):
                playlistStore.appendEntries(relativePaths: [rel], trackIDs: [tid], to: target.id)
                reused.append(ReusedTrack(
                    index: position + 1,
                    title: track.title,
                    artist: track.artists.map(\.name).joined(separator: ", ")))
            case .downloaded(let rel):
                playlistStore.appendEntries(relativePaths: [rel], trackIDs: [nil], to: target.id)
                downloaded += 1
            case .failed(let failure):
                failures.append(failure)
            case .skippedNoPath:
                break
            case .alreadyInPlaylist:
                alreadyInPlaylist += 1
            case .cancelled:
                break
            }
        }

        let windowSize = Self.maxConcurrent
        let stagger = Self.launchStagger
        await withTaskGroup(of: (Int, TrackResult).self) { group in
            var nextToLaunch = 0
            var nextToAppend = 0
            var buffered: [Int: TrackResult] = [:]
            var stopLaunching = false
            var launchTick = 0

            func launch(_ count: Int) {
                var launched = 0
                while launched < count, nextToLaunch < total, !stopLaunching {
                    let position = nextToLaunch
                    let track = tracks[position]
                    // Stagger so a freshly-primed window doesn't hit Lucida all
                    // at once. Slot within the window bounds the delay (0 …
                    // (maxConcurrent-1)·stagger); backfill launches after a
                    // completion are already naturally spaced.
                    let delay = UInt64(launchTick % windowSize) * stagger
                    group.addTask { [self] in
                        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                        return (position, await processTrack(
                            track, position: position, rootURL: rootURL, options: options,
                            existingPaths: existingPaths, existingIDs: existingIDs))
                    }
                    nextToLaunch += 1
                    launchTick += 1
                    launched += 1
                }
            }

            // Prime the window.
            launch(windowSize)

            while let (position, result) = await group.next() {
                completed += 1
                phase = .running(current: completed, total: total)
                buffered[position] = result

                // Flush every result that is now contiguous from the front, so
                // the playlist is built in order.
                while let r = buffered[nextToAppend] {
                    apply(r, at: nextToAppend)
                    buffered.removeValue(forKey: nextToAppend)
                    nextToAppend += 1
                }

                if case .cancelled = result { stopLaunching = true }
                if Task.isCancelled { stopLaunching = true }

                // Backfill the window with the next track.
                if !stopLaunching { launch(1) }
            }
        }

        // 3. Final library refresh so the new/updated playlist resolves.
        library.refreshLibrary()
        phase = .finished(Summary(
            playlistName: playlist.title, total: total,
            downloaded: downloaded, reused: reused, failures: failures,
            alreadyInPlaylist: alreadyInPlaylist, isResume: isResume
        ))
        currentTrackTitle = nil
    }

    /// Outcome of processing one track (computed off the ordered append step so
    /// concurrent tasks don't mutate the playlist directly).
    private enum TrackResult {
        case reused(relativePath: String, trackID: UUID?)
        case downloaded(relativePath: String)
        case failed(TrackFailure)
        case skippedNoPath
        case cancelled
        /// Track was already present in the existing local playlist — skip entirely.
        case alreadyInPlaylist
    }

    /// Duplicate-check → download for a single track. Returns a value; the caller appends to the
    /// playlist in order.
    ///
    /// `existingPaths` and `existingIDs` are the relative-path and trackID sets
    /// already in the target playlist; a track whose library file is already
    /// covered returns `.alreadyInPlaylist` so the caller skips it entirely.
    private func processTrack(
        _ track: RemoteTrack,
        position: Int,
        rootURL: URL,
        options: LucidaOptions,
        existingPaths: Set<String>,
        existingIDs: Set<UUID>
    ) async -> TrackResult {
        let artistLabel = track.artists.map(\.name).joined(separator: ", ")

        // Already in the library?
        if let existing = DownloadCoordinator.findExistingMatch(for: track, in: library.tracks) {
            if let rel = relativePath(of: existing.url, root: rootURL) {
                // Already in the playlist too — skip entirely (no re-add).
                if existingPaths.contains(rel) || existingIDs.contains(existing.id) {
                    return .alreadyInPlaylist
                }
                // In library but not yet in this playlist — reuse the file.
                return .reused(relativePath: rel, trackID: existing.id)
            }
            return .skippedNoPath
        }

        // Retry the whole download with backoff when it fails transiently.
        // Lucida refuses jobs when busy/rate-limited; a few spaced retries
        // turn those one-off refusals into successes instead of a failure wall.
        let sources = [track.url].compactMap { $0 }
        guard !sources.isEmpty else {
            return .failed(TrackFailure(index: position + 1, title: track.title,
                                        artist: artistLabel, reason: "No source URL."))
        }
        var outcome: DownloadCoordinator.JobOutcome = .failed("No source URL.")
        rounds: for attempt in 0..<Self.maxDownloadAttempts {
            // Track whether this round's failures were all *permanent* (no
            // matching release etc.). If so, retrying can't help — bail out
            // immediately instead of burning attempts and initiations.
            var allPermanent = true
            for source in sources {
                if Task.isCancelled { outcome = .cancelled; break rounds }
                outcome = await download(track, sourceURL: source, options: options)
                switch outcome {
                case .completed, .skipped, .cancelled: break rounds
                case .failed(let reason):
                    if !Self.isPermanentFailure(reason) { allPermanent = false }
                    continue   // try next source this round
                }
            }
            if case .cancelled = outcome { break }
            // Every source failed permanently → don't retry.
            if allPermanent { break rounds }
            // Transient (busy / rate-limited): back off with jitter before the
            // next round. Longer than before so Lucida's limiter actually cools
            // down rather than being hammered again immediately.
            if attempt < Self.maxDownloadAttempts - 1 {
                try? await Task.sleep(nanoseconds: Self.transientBackoff(attempt: attempt))
            }
        }

        switch outcome {
        case .completed(let url):
            if let rel = relativePath(of: url, root: rootURL) { return .downloaded(relativePath: rel) }
            return .skippedNoPath
        case .skipped(let url):
            let tid = library.tracks.first { $0.url == url }?.id
            if let rel = relativePath(of: url, root: rootURL) {
                return .reused(relativePath: rel, trackID: tid)
            }
            return .skippedNoPath
        case .failed(let reason):
            return .failed(TrackFailure(index: position + 1, title: track.title,
                                        artist: artistLabel, reason: reason))
        case .cancelled:
            return .cancelled
        }
    }

    /// Build a download track pointing at `sourceURL`, stamp options on the
    /// Lucida provider, and await its terminal outcome.
    private func download(
        _ track: RemoteTrack,
        sourceURL: URL?,
        options: LucidaOptions
    ) async -> DownloadCoordinator.JobOutcome {
        guard let sourceURL else { return .failed("No source URL for \(track.title).") }
        let enqueueTrack = track.withSource(url: sourceURL)
        // Force Lucida to embed tags + cover from the source, since we trust
        // those over our title-only metadata and skip our own re-tagging.
        var embedOptions = options
        embedOptions.addMetadata = true
        lucidaProvider.setOptions(embedOptions, for: enqueueTrack)
        return await downloads.enqueueAndAwait(enqueueTrack, trustEmbeddedMetadata: true)
    }

    // MARK: - Failure classification

    /// True when a failure reason indicates a *permanent* problem (no matching
    /// release, unsupported/region-locked source) that retrying can't fix.
    /// Everything else — busy, rate-limited, timeouts, generic "couldn't start"
    /// — is treated as transient and retried with backoff.
    static func isPermanentFailure(_ reason: String) -> Bool {
        let r = reason.lowercased()
        let permanent = [
            "no match", "no matching", "not found", "no results", "no result",
            "unsupported", "no source", "region", "not available", "unavailable in",
            "invalid", "doesn't look", "couldn't find", "could not find",
        ]
        return permanent.contains { r.contains($0) }
    }

    /// Backoff before the next retry round for a transient failure: ~3s, ~8s,
    /// ~20s with jitter, so Lucida's per-IP limiter actually cools down instead
    /// of being hit again on a fixed cadence.
    static func transientBackoff(attempt: Int) -> UInt64 {
        let base: [Double] = [3, 8, 20]
        let seconds = base[min(attempt, base.count - 1)] + Double.random(in: 0...1.5)
        return UInt64(seconds * 1_000_000_000)
    }

    // MARK: - Helpers

    private func fetchArtwork(_ coverArt: [RemoteCoverArt]) async -> Data? {
        guard let best = RemoteCoverArt.best(coverArt) else { return nil }
        do {
            let (data, _) = try await urlSession.data(from: best.url)
            return data
        } catch {
            return nil
        }
    }

    /// Returns the path of `fileURL` relative to the library root, or `nil` if
    /// it isn't under the root. Mirrors `PlaylistStore.addTracks`.
    private func relativePath(of fileURL: URL, root: URL) -> String? {
        let rootPath = root.path
        let filePath = fileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }
}

// MARK: - RemoteTrack source swap

extension RemoteTrack {
    /// A copy of this track that downloads from `url` instead of its original
    /// service URL. A distinct `id` keeps the Lucida per-track options dictionary
    /// from colliding when the same track is enqueued twice (Amazon then the
    /// Spotify fallback).
    func withSource(url: URL) -> RemoteTrack {
        RemoteTrack(
            id: "\(id)|src:\(url.absoluteString)",
            title: title,
            artists: artists,
            album: album,
            trackNumber: trackNumber,
            discNumber: discNumber,
            durationSeconds: durationSeconds,
            coverArt: coverArt,
            url: url,
            serviceID: serviceID,
            isLossless: isLossless
        )
    }
}
