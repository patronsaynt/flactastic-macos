import Foundation
import Observation

/// Coordinates lazy, deduplicated lyrics fetches against lrclib.net.
/// Mirrors `ArtistImageFetcher`: views call `ensureLyrics(for:)` from a
/// `.task`; the cache (`@Observable`) re-publishes when an entry arrives,
/// and the view re-renders.
@Observable
@MainActor
final class LyricsFetcher {
    private let cache: LyricsRemoteCache
    private let client: LrcLibClient
    /// Optional writer used to persist fetched lyrics back into the audio
    /// file's metadata when the user has enabled that setting.
    private let metadataWriter: MetadataWriter?
    private var inFlight: Set<String> = []
    /// Transient errors (timeouts, 5xx) keyed by cache key. Not persisted —
    /// the entry expires after `errorTTL` so a retry happens automatically
    /// next time the user plays the song. Long enough to suppress noisy
    /// re-fetches for the rest of a normal listening session, short enough
    /// that a temporary outage clears itself before the next session.
    private(set) var recentErrors: [String: Date] = [:]
    private let errorTTL: TimeInterval = 300
    /// Cooldown for transport-level failures that the client already retried
    /// and that say nothing about whether lrclib has this track. Kept short
    /// so a brief connectivity blip doesn't lock out a whole album for the
    /// full `errorTTL`; the next play retries almost immediately.
    private let transportErrorTTL: TimeInterval = 20
    /// Keys whose last failure was transport-level, so `hasRecentError` can
    /// apply `transportErrorTTL` instead of the full `errorTTL`.
    private var transportErrorKeys: Set<String> = []
    /// Where `track`'s file lives now. A fetch captures the track's URL when
    /// it starts; if the Organizer moves or renames the file before the
    /// response arrives, embedding must follow the file to its new path.
    private let resolveCurrentURL: (@MainActor (Track) -> URL?)?

    init(cache: LyricsRemoteCache,
         client: LrcLibClient = .shared,
         metadataWriter: MetadataWriter? = nil,
         resolveCurrentURL: (@MainActor (Track) -> URL?)? = nil) {
        self.cache = cache
        self.client = client
        self.metadataWriter = metadataWriter
        self.resolveCurrentURL = resolveCurrentURL
    }

    /// True when a recent fetch attempt for this key failed transiently
    /// (i.e. we should surface "Unable to find lyrics" instead of spinning).
    func hasRecentError(forKey key: String) -> Bool {
        guard let when = recentErrors[key] else { return false }
        let ttl = transportErrorKeys.contains(key) ? transportErrorTTL : errorTTL
        return Date().timeIntervalSince(when) < ttl
    }

    /// If a fresh cached entry exists, parse and return it. Otherwise — when
    /// `enabled` is true — kick off a background fetch (deduped by key) and
    /// return nil. Callers observe `cache.entries` for updates.
    ///
    /// The `priority` parameter lets the visualizer fire the current track's
    /// fetch at `.userInitiated` while prefetch passes use `.background`,
    /// so the visible lyrics aren't stuck behind speculative work.
    @discardableResult
    /// The lyrics lookup for this track is over: found (cached), failed
    /// recently, or not running.
    func isSettled(_ track: Track) -> Bool {
        let key = LyricsCacheKey.make(artist: track.artist ?? track.albumArtist, title: track.title, duration: track.duration)
        if cache.entry(forKey: key) != nil || hasRecentError(forKey: key) { return true }
        return !inFlight.contains(key)
    }

    func ensureLyrics(
        for track: Track?,
        enabled: Bool,
        saveToFile: Bool = false,
        priority: TaskPriority = .userInitiated,
        startDelay: TimeInterval = 0
    ) -> Lyrics? {
        guard let track else { return nil }
        // Mix compilations (live sets, mixes, radio shows) must never carry
        // or seek lyrics — this is a defensive second guard behind the
        // primary check at the visualizer call site.
        guard track.isMixCompilation != true else { return nil }
        let key = LyricsCacheKey.make(
            artist: track.artist ?? track.albumArtist,
            title: track.title,
            duration: track.duration
        )

        if let entry = cache.entry(forKey: key), cache.isFresh(forKey: key) {
            return parsedLyrics(from: entry, duration: track.duration ?? 0)
        }

        guard enabled else { return nil }
        guard !inFlight.contains(key) else { return nil }
        // Stay quiet on tracks that just failed — don't re-hit the network
        // for a known-bad key while the cooldown is still active. View
        // already shows "Unable to find lyrics" via `hasRecentError`.
        guard !hasRecentError(forKey: key) else { return nil }

        inFlight.insert(key)
        let writer = metadataWriter
        Task(priority: priority) { [weak self, client] in
            defer {
                Task { @MainActor in self?.inFlight.remove(key) }
            }
            if startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            }

            // Step 1 — read embedded lyrics from the file first. If present,
            // detect synced (LRC bracket) vs plain text and seed the cache;
            // skip the network entirely. Saves a round-trip and avoids
            // hitting lrclib for tracks the user has already tagged.
            if let writer, let stored = try? await writer.readLyrics(from: track),
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let looksSynced = stored.contains("[") && stored.range(
                    of: #"\[\d{1,2}:\d{2}"#,
                    options: .regularExpression
                ) != nil
                await MainActor.run {
                    if looksSynced {
                        self?.cache.setEntry(LyricsCacheEntry(
                            key: key, syncedLyrics: stored
                        ))
                    } else {
                        self?.cache.setEntry(LyricsCacheEntry(
                            key: key, plainLyrics: stored
                        ))
                    }
                }
                return
            }

            // Step 2 — fall back to lrclib.
            do {
                // lrclib matches best on a single primary artist. Strip
                // multi-artist credits ("A, B" / "A & B" / "A feat. B") to
                // their first piece for the query — album_name + duration
                // already help disambiguate compilation/feature credits.
                let artistRaw = LyricsFetcher.primaryArtist(
                    from: track.artist ?? track.albumArtist
                ) ?? ""
                let response = try await client.fetchLyrics(
                    artist: artistRaw,
                    title: track.title,
                    album: track.album,
                    duration: track.duration
                )
                let foundLyrics = response != nil
                    && !(response?.instrumental ?? false)
                    && (response?.syncedLyrics?.isEmpty == false
                        || response?.plainLyrics?.isEmpty == false)

                await MainActor.run {
                    // A result of any kind clears a prior failure for this key.
                    self?.recentErrors.removeValue(forKey: key)
                    self?.transportErrorKeys.remove(key)
                    if foundLyrics, let response {
                        self?.cache.setEntry(LyricsCacheEntry(
                            key: key,
                            plainLyrics: response.plainLyrics,
                            syncedLyrics: response.syncedLyrics
                        ))
                    } else {
                        self?.cache.setEntry(LyricsCacheEntry(key: key, notFound: true))
                    }
                }

                // Embed lyrics into the source file when the user opted in.
                // Prefer synced LRC (other LRC-aware players will still parse
                // it); fall back to plain text. Errors are non-fatal — the
                // network result is already cached for the visualizer.
                if saveToFile, foundLyrics, let writer, let response {
                    let payload = (response.syncedLyrics?.isEmpty == false
                                   ? response.syncedLyrics
                                   : response.plainLyrics)
                    if let payload, !payload.isEmpty {
                        var target = track
                        if !FileManager.default.fileExists(atPath: track.url.path) {
                            // Moved since the fetch started (e.g. an Organizer
                            // run mid-playback) — write to where it is now.
                            let moved = await MainActor.run { self?.resolveCurrentURL?(track) }
                            if let moved { target = track.withURL(moved) }
                        }
                        do {
                            try await writer.writeLyrics(to: target, lyrics: payload)
                        } catch {
                            print("[LyricsFetcher] Failed to embed lyrics in \(target.url.lastPathComponent): \(error)")
                        }
                    }
                }
            } catch {
                // Concise one-liner — don't dump the full URLError UserInfo
                // tree to the debug console.
                let summary = LyricsFetcher.summarize(error: error)
                print("[LyricsFetcher] \(track.title): \(summary)")
                // Don't poison the persistent cache for transient errors —
                // mark the in-memory error slot so the view shows the
                // "Unable to find lyrics" message and we don't immediately
                // retry the same key during prefetch passes.
                let isTransport = error is URLError
                await MainActor.run {
                    self?.recentErrors[key] = Date()
                    if isTransport {
                        self?.transportErrorKeys.insert(key)
                    } else {
                        self?.transportErrorKeys.remove(key)
                    }
                }
            }
        }
        return nil
    }

    /// Compress noisy `URLError` / `LrcLibClientError` payloads into a
    /// short, human-readable summary suitable for one-line debug logs.
    private static func summarize(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:                 return "timed out"
            case .notConnectedToInternet:   return "offline"
            case .networkConnectionLost:    return "connection lost"
            case .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:          return "host unreachable"
            default:                        return "network error (\(urlError.code.rawValue))"
            }
        }
        if let clientError = error as? LrcLibClientError {
            switch clientError {
            case .invalidQuery:             return "invalid query"
            case .badResponse(let code):    return "http \(code)"
            }
        }
        return String(describing: error)
    }

    /// Reduce a possibly multi-artist credit string ("Future, Metro Boomin")
    /// down to the primary artist ("Future") for lrclib lookups.
    private static func primaryArtist(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Honour the app's explicit storage delimiters first.
        if let pieces = ArtistResolver.explicitlySeparated(trimmed),
           let first = pieces.first {
            return first
        }
        // Heuristic: split on common collaboration tokens.
        let separators = [", ", " & ", " feat. ", " feat ", " ft. ", " ft ",
                          " x ", " X ", " vs. ", " vs "]
        var head = trimmed
        for sep in separators {
            if let range = head.range(of: sep, options: .caseInsensitive) {
                head = String(head[..<range.lowerBound])
            }
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Warm the cache for the tracks the user is likely to hear next. Runs
    /// at `.background` priority and with a small staggered delay per track
    /// so the visible song's request always wins the network race.
    /// Already-cached / in-flight entries are no-ops.
    func prefetch(tracks: [Track], enabled: Bool, saveToFile: Bool = false) {
        guard enabled else { return }
        for (i, track) in tracks.enumerated() {
            // 0.6s lead time before the first prefetch, then 0.3s between
            // each — enough for the foreground request to be well in flight.
            let delay = 0.6 + Double(i) * 0.3
            ensureLyrics(
                for: track,
                enabled: true,
                saveToFile: saveToFile,
                priority: .background,
                startDelay: delay
            )
        }
    }

    /// Parse a cache entry into renderable lyrics. Prefers synced LRC; falls
    /// back to plain text distributed across the track's duration.
    func parsedLyrics(from entry: LyricsCacheEntry, duration: TimeInterval) -> Lyrics? {
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            let parsed = Lyrics.parseLRC(synced)
            if !parsed.lines.isEmpty { return parsed }
        }
        if let plain = entry.plainLyrics, !plain.isEmpty {
            return Lyrics.fromPlainText(plain, duration: duration)
        }
        return nil
    }
}
