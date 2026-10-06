import Foundation
import Observation
import SwiftUI

/// Orchestrates: provider.getStream → write to temp → tag → move into library
/// → trigger LibraryStore rescan. Owns a serial queue per service so a single
/// flaky provider can't block another.
@Observable
@MainActor
final class DownloadCoordinator {
    enum JobStatus: Sendable, Equatable {
        case queued
        case downloading(receivedBytes: Int64, totalBytes: Int64?)
        case tagging
        case finishing
        case completed(URL)
        case failed(String)
        /// User aborted via `cancel(_:)` — the in-flight WKDownload (if any)
        /// is torn down and the temp file is cleaned up.
        case cancelled
        /// A track with matching title + artist already exists in the
        /// library. We don't re-download; the existing file's URL is shown
        /// so the user can find it.
        case skipped(URL)

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .skipped: return true
            default: return false
            }
        }
        /// Only in-flight jobs (anything before completion/failure) can be
        /// cancelled. Used by the UI to gate the cancel button.
        var canCancel: Bool { !isTerminal }
    }

    /// Terminal result of a single job, returned by `enqueueAndAwait(_:)` so a
    /// caller (e.g. PlaylistRebuildCoordinator) can sequence work per track.
    enum JobOutcome: Sendable {
        case completed(URL)
        case skipped(URL)
        case failed(String)
        case cancelled

        var status: JobStatus {
            switch self {
            case .completed(let u): return .completed(u)
            case .skipped(let u):   return .skipped(u)
            case .failed(let m):    return .failed(m)
            case .cancelled:        return .cancelled
            }
        }
    }

    struct Job: Identifiable, Sendable {
        let id: UUID
        let track: RemoteTrack
        var status: JobStatus
        /// When true, the file Lucida hands back is left tagged exactly as
        /// Lucida embedded it (real album/artist/cover from the source) instead
        /// of being re-tagged from our `RemoteTrack`. Used by the Spotify
        /// playlist rebuild, whose `RemoteTrack`s carry only title + artist.
        var trustEmbeddedMetadata: Bool = false
    }

    private(set) var jobs: [Job] = []

    /// Continuations for callers awaiting a job's terminal outcome via
    /// `enqueueAndAwait(_:)`. Resolved exactly once in `finish(_:_:)`.
    private var outcomeWaiters: [UUID: CheckedContinuation<JobOutcome, Never>] = [:]

    private let registry: StreamerRegistry
    private let library: LibraryStore
    private let writer: MetadataWriter
    private let urlSession: URLSession

    /// Per-job Task handle so `cancel(_:)` can interrupt the pipeline. The
    /// Task tear-down propagates through `AsyncThrowingStream.onTermination`
    /// to the underlying provider (WKDownload, URLSession) and cleans temp
    /// files.
    private var jobTasks: [UUID: Task<Void, Never>] = [:]

    /// Debounces the post-download library rescan. An album download used to
    /// trigger one full filesystem rescan per completed file; now the rescan
    /// fires once, ~1.5 s after the most recent completion. Dedupe safety is
    /// unaffected: `enqueue` guards in-flight duplicates by track+service, and
    /// the on-disk `findExistingMatch` check runs before each download starts.
    private var refreshDebounceTask: Task<Void, Never>?

    private func scheduleLibraryRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.library.refreshLibrary()
        }
    }

    init(
        registry: StreamerRegistry,
        library: LibraryStore,
        writer: MetadataWriter,
        urlSession: URLSession = .shared
    ) {
        self.registry = registry
        self.library = library
        self.writer = writer
        self.urlSession = urlSession
    }

    // MARK: - Public API

    func enqueue(_ track: RemoteTrack) {
        // In-flight duplicate guard: if this exact track already has an active
        // (non-terminal) job, don't enqueue it again. Keeps "Download album"
        // plus per-track taps — or a double-click — from downloading twice.
        // (Already-on-disk duplicates are caught separately in `run` via
        // `findExistingMatch`.)
        if jobs.contains(where: {
            $0.track.id == track.id
                && $0.track.serviceID == track.serviceID
                && $0.status.canCancel
        }) {
            return
        }
        let job = Job(id: UUID(), track: track, status: .queued)
        jobs.append(job)
        let id = job.id
        jobTasks[id] = Task { [weak self] in
            await self?.run(jobID: id)
            self?.removeJobTask(id)
        }
    }

    /// Drop the finished Task's handle. Main-actor isolated so callers from
    /// the cooperative pool hop here once their `run` returns.
    private func removeJobTask(_ id: UUID) {
        jobTasks.removeValue(forKey: id)
    }

    func enqueue(_ tracks: [RemoteTrack]) {
        for t in tracks { enqueue(t) }
    }

    /// Enqueue a single track and suspend until it reaches a terminal state,
    /// returning the outcome. The job still appears in `jobs` (so the UI shows
    /// per-track progress and a Cancel button) — this just lets a caller drive
    /// downloads serially. Cancelling via `cancel(_:)` resolves the await with
    /// `.cancelled`.
    func enqueueAndAwait(
        _ track: RemoteTrack,
        trustEmbeddedMetadata: Bool = false
    ) async -> JobOutcome {
        let job = Job(id: UUID(), track: track, status: .queued,
                      trustEmbeddedMetadata: trustEmbeddedMetadata)
        jobs.append(job)
        let id = job.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Stored synchronously before the Task can run, so `finish`
                // always finds the waiter.
                outcomeWaiters[id] = continuation
                jobTasks[id] = Task { [weak self] in
                    await self?.run(jobID: id)
                    self?.removeJobTask(id)
                }
            }
        } onCancel: {
            // If the awaiting task (e.g. a playlist rebuild) is cancelled, tear
            // down the in-flight download and resolve the await with .cancelled.
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    /// Cancel an in-flight job. Cancelling a terminal job is a no-op. The
    /// Task's cancellation propagates through `AsyncThrowingStream` —
    /// WKDownload sees its byte stream terminate and stops fetching.
    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status.canCancel else { return }
        jobTasks[id]?.cancel()
        finish(id, .cancelled)
    }

    /// Cancel every in-flight job. Terminal jobs are untouched.
    func cancelAll() {
        for job in jobs where job.status.canCancel {
            cancel(job.id)
        }
    }

    func clearCompleted() {
        jobs.removeAll { $0.status.isTerminal }
    }

    // MARK: - Job pipeline

    private func update(_ id: UUID, _ status: JobStatus) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = status
    }

    /// Set a job's terminal status and resolve any `enqueueAndAwait` waiter.
    /// Centralizes every terminal transition so the continuation is resumed
    /// exactly once. Safe to call when no waiter exists (plain `enqueue` jobs).
    private func finish(_ id: UUID, _ outcome: JobOutcome) {
        update(id, outcome.status)
        if let waiter = outcomeWaiters.removeValue(forKey: id) {
            waiter.resume(returning: outcome)
        }
    }

    private func run(jobID: UUID) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let track = job.track

        guard let provider = registry.provider(serviceID: track.serviceID) else {
            finish(jobID, .failed("Provider \"\(track.serviceID)\" no longer registered."))
            return
        }
        guard let rootURL = library.rootURL else {
            finish(jobID, .failed("No music folder selected. Open Settings → Config first."))
            return
        }

        // Duplicate guard: if a track with the same title + primary artist is
        // already in the library, skip the network round-trip. Match is case-
        // insensitive and whitespace-trimmed so trivial differences (e.g.
        // trailing space, capitalisation) don't cause double-downloads.
        if let existing = Self.findExistingMatch(for: track, in: library.tracks) {
            finish(jobID, .skipped(existing.url))
            return
        }

        do {
            update(jobID, .downloading(receivedBytes: 0, totalBytes: nil))
            let stream = try await provider.getStream(for: track)
            update(jobID, .downloading(receivedBytes: 0, totalBytes: stream.sizeBytes))

            // Stream to a temp file. We can't write tags into the stream
            // directly because TagLib needs random access; tag once the file
            // is fully on disk.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("flactastic-dl-\(jobID.uuidString).\(stream.suggestedExtension)")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            // Throttle progress publication: `jobs` is @Observable, so an
            // update per network chunk re-renders the download UI at
            // network-chunk cadence (hundreds of invalidations per file).
            // Report at most every 256 KB or 100 ms, plus a final update.
            var received: Int64 = 0
            var lastReportedBytes: Int64 = 0
            var lastReportTime = ContinuousClock.now
            for try await chunk in stream.bytes {
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                if received - lastReportedBytes >= 262_144
                    || lastReportTime.duration(to: .now) >= .milliseconds(100) {
                    lastReportedBytes = received
                    lastReportTime = .now
                    update(jobID, .downloading(receivedBytes: received, totalBytes: stream.sizeBytes))
                }
            }
            if received != lastReportedBytes {
                update(jobID, .downloading(receivedBytes: received, totalBytes: stream.sizeBytes))
            }
            try handle.close()

            // Some sources (SoundCloud via Lucida) deliver audio in an MP4
            // container. Convert to .m4a so tagging and the library pick it
            // up; everything else passes through untouched.
            let stagedURL = try await AudioContainerNormalizer.normalize(tempURL)
            let ext = stagedURL.pathExtension

            // --- Tag the file using metadata we already have from the provider.
            // Playlist rebuilds skip the full re-tag: Lucida already embedded the
            // real album/artist/cover from the source, and our RemoteTrack only
            // has title + artist, so re-tagging would clobber good data. We do
            // still override the title with the playlist's canonical (Spotify)
            // name, since the source service often mangles remix/edit titles
            // (e.g. "Miami 82 - Avicii Edit" → "Miami 82 (Avicii)").
            if job.trustEmbeddedMetadata {
                if !track.title.isEmpty {
                    update(jobID, .tagging)
                    try? await writer.overrideTitle(at: stagedURL, title: track.title)
                }
            } else {
                update(jobID, .tagging)
                let artworkData = await Self.fetchArtwork(track: track, session: urlSession)
                let format = AudioFileFormat.classify(stagedURL) ?? .flac
                let joinedArtists = track.artists.map(\.name).joined(separator: "; ")
                let artistTag = joinedArtists.isEmpty ? nil : joinedArtists
                let primaryArtist = track.artists.first?.name
                let stagedTrack = Track(
                    url: stagedURL,
                    title: track.title,
                    artist: artistTag,
                    albumArtist: track.album?.title.isEmpty == false ? primaryArtist : nil,
                    album: track.album?.title,
                    trackNumber: track.trackNumber,
                    duration: track.durationSeconds,
                    artwork: artworkData,
                    fileFormat: format,
                    year: track.album?.releaseYear,
                    isCompilation: false
                )

                _ = try await writer.write(
                    to: stagedTrack,
                    title: track.title,
                    artist: artistTag,
                    album: track.album?.title,
                    year: track.album?.releaseYear,
                    genre: nil,
                    trackNumber: track.trackNumber,
                    artworkChange: artworkData.map { .updated($0) } ?? .unchanged,
                    albumArtistChange: .set(primaryArtist),
                    compilationChange: .unchanged
                )
            }

            // --- Move into library at Artist/Album/NN - Title.ext.
            update(jobID, .finishing)
            let finalURL = try Self.finalDestination(
                rootURL: rootURL,
                track: track,
                ext: ext
            )
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // If a file already exists at the destination, append a UUID
            // suffix rather than overwriting the user's existing copy.
            var dest = finalURL
            if FileManager.default.fileExists(atPath: dest.path) {
                let stem = finalURL.deletingPathExtension().lastPathComponent
                let parent = finalURL.deletingLastPathComponent()
                dest = parent.appendingPathComponent("\(stem) (\(UUID().uuidString.prefix(8))).\(ext)")
            }
            try FileManager.default.moveItem(at: stagedURL, to: dest)

            finish(jobID, .completed(dest))
            scheduleLibraryRefresh()
        } catch is CancellationError {
            // Task was cancelled via `cancel(_:)`. The status has already
            // been set to `.cancelled` there; don't overwrite with a
            // generic .failed.
            return
        } catch {
            // A torn-down AsyncThrowingStream raised by `Task.cancel()`
            // surfaces as URLError(.cancelled) here, not CancellationError.
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            // Must be `finish`, not `update`: a caller awaiting via
            // `enqueueAndAwait` (the playlist rebuild) needs its continuation
            // resolved here, or a single failed track hangs the whole rebuild.
            finish(jobID, .failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }

    /// Returns the library `Track` that is the same recording as `remote`, or
    /// `nil` if the track isn't in the library yet.
    ///
    /// Duplicate detection has to bridge cross-service naming: the same song is
    /// tagged "Miami 82 - Avicii Edit" on one service and "Miami 82 (Avicii)" on
    /// another, may or may not carry a leading "NN - " track number in the file
    /// name, and the embedded tag title can differ from the file name. So we try
    /// a series of progressively looser strategies and stop at the first one
    /// that yields a confident match:
    ///
    ///   1. Exact file-name match (the strongest signal — FLACtastic names files
    ///      from the source title, so a byte-for-byte file-name hit is the same
    ///      track regardless of artist folder).
    ///   2. Exact tag-title match.
    ///   3. Loose file-name match (version markers / punctuation flattened).
    ///   4. Loose tag-title match.
    ///
    /// For each strategy we collect every library track that matches the title
    /// key, then require the match to share an **artist or album** with the
    /// remote track — a title alone is never enough, since distinct recordings
    /// (covers, same title by different artists) routinely collide. A bare
    /// title-only match is accepted only when the remote track carries no
    /// artist/album info to disambiguate on (so we can't do any better).
    ///
    /// Exposed so the playlist rebuild can pre-check duplicates before spending
    /// a source lookup on a track it won't download.
    static func findExistingMatch(for remote: RemoteTrack, in tracks: [Track]) -> Track? {
        let exactKey = normalize(remote.title)
        guard !exactKey.isEmpty else { return nil }
        let looseKey = looseTitle(remote.title)

        let remoteArtists = artistTokens(remote.artists.map(\.name).joined(separator: "; "))
        let remoteAlbum = remote.album.map { normalize($0.title) } ?? ""

        // Precompute comparable keys for every library track once.
        let keyed: [(track: Track, fileExact: String, fileLoose: String,
                     tagExact: String, tagLoose: String)] = tracks.map { t in
            var stem = t.url.deletingPathExtension().lastPathComponent
            let stemRange = NSRange(stem.startIndex..., in: stem)
            if let m = Self.leadingTrackNumber.firstMatch(in: stem, range: stemRange),
               let r = Range(m.range, in: stem) {
                stem = String(stem[r.upperBound...])
            }
            return (t, normalize(stem), looseTitle(stem), normalize(t.title), looseTitle(t.title))
        }

        // Strategy tiers, tried in order. `requireOverlap` gates the looser
        // tiers on artist/album overlap to avoid false positives.
        let tiers: [(key: String, keyPath: (Int) -> String, requireOverlap: Bool)] = [
            (exactKey, { keyed[$0].fileExact }, false),
            (exactKey, { keyed[$0].tagExact },  false),
            (looseKey, { keyed[$0].fileLoose }, true),
            (looseKey, { keyed[$0].tagLoose },  true),
        ]

        // A title match alone is never enough to call something a duplicate —
        // many distinct recordings share a title (covers, different artists).
        // We require the library track to share an artist or the album with the
        // remote track. A bare title-only match is accepted *only* when we have
        // no artist/album info on the remote track to compare against (so we
        // can't do any better).
        let canDisambiguate = !remoteArtists.isEmpty || !remoteAlbum.isEmpty

        for tier in tiers {
            guard !tier.key.isEmpty else { continue }
            let hits = keyed.indices.filter { tier.keyPath($0) == tier.key }.map { keyed[$0].track }
            guard !hits.isEmpty else { continue }

            // Prefer a hit that shares an artist or album.
            if let m = hits.first(where: { overlaps($0, remoteArtists: remoteArtists, remoteAlbum: remoteAlbum) }) {
                return m
            }

            // No artist/album overlap. The loose tiers always demand it; the
            // exact-title tiers accept a title-only match only when there's
            // nothing to disambiguate on. Otherwise this is a same-title but
            // different recording — not a duplicate — so keep looking.
            if tier.requireOverlap || canDisambiguate { continue }
            return hits[0]
        }
        return nil
    }

    /// True when a library track shares an artist token or its album name with
    /// the remote track (used to disambiguate same-title matches).
    ///
    /// When *both* sides carry artist info and no artist matches, that's a
    /// veto: they're different recordings, full stop. The album name is only
    /// consulted when one side lacks artist info — otherwise a self-titled
    /// single ("Kiss" by X vs the single "Kiss" by Y, both on an album named
    /// "Kiss") would falsely read as the same track.
    private static func overlaps(_ t: Track, remoteArtists: Set<String>, remoteAlbum: String) -> Bool {
        let libArtists = artistTokens(t.artist).union(artistTokens(t.albumArtist))
        if !remoteArtists.isEmpty, !libArtists.isEmpty {
            return !remoteArtists.isDisjoint(with: libArtists)
        }
        if !remoteAlbum.isEmpty, normalize(t.album ?? "") == remoteAlbum { return true }
        return false
    }

    /// Compiled once — this used to be re-compiled per library track per job
    /// via `range(of:options:.regularExpression)`. `nonisolated(unsafe)` is
    /// sound here: NSRegularExpression is documented immutable & thread-safe.
    nonisolated(unsafe) private static let leadingTrackNumber =
        try! NSRegularExpression(pattern: #"^\d{1,3}\s*-\s*"#)

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A forgiving title key: lowercased, with version markers (" - " and any
    /// parenth/bracket grouping) flattened and whitespace collapsed, so the
    /// same track tagged "Song - Radio Edit" or "Song (Radio Edit)" compares
    /// equal across services.
    private static func looseTitle(_ s: String) -> String {
        var t = s.lowercased()
        for ch in ["(", ")", "[", "]"] { t = t.replacingOccurrences(of: ch, with: " ") }
        t = t.replacingOccurrences(of: " - ", with: " ")
        let collapsed = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return collapsed.joined(separator: " ")
    }

    /// Split a (possibly multi-artist) artist tag into a set of normalized
    /// names, tolerating the separators different services use (";", ",", "&",
    /// "/", "feat."/"ft.").
    private static func artistTokens(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty else { return [] }
        var working = raw.lowercased()
        for marker in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
            working = working.replacingOccurrences(of: marker, with: ";")
        }
        let parts = working.components(separatedBy: CharacterSet(charactersIn: ";,&/"))
        return Set(parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    // MARK: - Helpers

    private static func fetchArtwork(track: RemoteTrack, session: URLSession) async -> Data? {
        let arts = !track.coverArt.isEmpty ? track.coverArt : (track.album?.coverArt ?? [])
        guard let best = RemoteCoverArt.best(arts) else { return nil }
        // SoundCloud metadata points at a thumbnail; swap in the original upload.
        if SoundCloudArtwork.isArtworkURL(best.url),
           let jpeg = await SoundCloudArtwork.fetchBestJPEG(from: best.url, session: session) {
            return jpeg
        }
        do {
            let (data, _) = try await session.data(from: best.url)
            return data
        } catch {
            return nil
        }
    }

    /// Builds <root>/<albumArtist>/<album>/NN - <title>.<ext>, with each path
    /// component sanitised against macOS-illegal characters.
    private static func finalDestination(rootURL: URL, track: RemoteTrack, ext: String) throws -> URL {
        let artistDir = sanitize(track.artists.first?.name ?? "Unknown Artist")
        let albumDir = sanitize(track.album?.title ?? "Singles")
        let trackPrefix = track.trackNumber.map { String(format: "%02d - ", $0) } ?? ""
        let filename = sanitize(trackPrefix + track.title) + "." + ext
        return rootURL
            .appendingPathComponent(artistDir)
            .appendingPathComponent(albumDir)
            .appendingPathComponent(filename)
    }

    private static func sanitize(_ raw: String) -> String {
        // ":" and "/" are the two characters macOS Finder forbids in path
        // components. Everything else (including emoji) survives.
        let bad: Set<Character> = ["/", ":"]
        let cleaned = String(raw.map { bad.contains($0) ? "-" : $0 })
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled" }
        // Files starting with "." are hidden on macOS/Unix; prefix with "_" to keep them visible.
        return trimmed.hasPrefix(".") ? "_" + trimmed : trimmed
    }
}
