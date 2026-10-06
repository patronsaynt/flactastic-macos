import Foundation
import WebKit

/// `StreamerProvider` backed by the lucida.to web service.
///
/// Goals:
///  - Zero user input — no accounts, no tokens, no settings UI.
///  - Anything lucida.to supports (Spotify / Tidal / Qobuz / Apple Music /
///    Deezer / SoundCloud / YouTube Music / Amazon Music / etc.) lands in
///    the library tagged.
///
/// All HTTP work happens inside a hidden `WKWebView` that has cleared
/// Cloudflare's bot challenge — see `LucidaWebController`.
@MainActor
final class LucidaWebProvider: NSObject, StreamerProvider {

    // MARK: - StreamerProvider conformance

    let serviceID = "lucida"
    let displayName = "Lucida"
    /// Hosts the lucida.to frontend accepts as paste targets. Listed
    /// individually because `StreamerRegistry.provider(for:)` does exact-host
    /// matching with `www.` stripping — no suffix wildcards.
    let hostnames: [String] = [
        "open.spotify.com", "spotify.com",
        "tidal.com", "listen.tidal.com",
        "qobuz.com", "play.qobuz.com", "open.qobuz.com",
        "deezer.com",
        "soundcloud.com", "on.soundcloud.com",
        "music.apple.com",
        "music.amazon.com", "music.amazon.co.uk",
        "music.youtube.com",
        "lucida.to",
    ]
    var isConfigured: Bool { true }

    // MARK: - Initiation throttle

    /// Minimum spacing between Lucida job initiations (`streamV2`), enforced
    /// globally across every in-flight download. Lucida rate-limits job *starts*
    /// per IP, so pacing initiations — rather than just capping how many run at
    /// once — is what actually keeps us under the limit. Jitter keeps the cadence
    /// irregular so the limiter can't pattern-match a fixed beat.
    private static let minInitiationInterval: TimeInterval = 1.75
    private static let initiationJitter: TimeInterval = 0.5
    private var nextInitiationAllowed = Date.distantPast

    /// Reserve the next initiation slot and sleep until it arrives. Safe under
    /// main-actor reentrancy: the reservation (read-now → write-next) is
    /// synchronous and atomic, so concurrent callers each claim a distinct,
    /// increasing slot, then sleep in parallel until theirs comes up.
    private func awaitInitiationSlot() async {
        let now = Date()
        let slot = max(now, nextInitiationAllowed)
        let interval = Self.minInitiationInterval + Double.random(in: 0...Self.initiationJitter)
        nextInitiationAllowed = slot.addingTimeInterval(interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    func login() async throws {
        try await controller.awaitReady()
    }

    func accountInfo() async throws -> StreamerAccount {
        try await controller.awaitReady()
        return StreamerAccount(
            displayName: "Anonymous via lucida.to",
            country: nil, lossless: true, hiRes: true
        )
    }

    /// Lucida's frontend has no free-text search endpoint; it's paste-URL
    /// only. We surface this honestly rather than fake catalog results.
    func search(_ query: String, limit: Int) async throws -> StreamerSearchResults {
        StreamerSearchResults(query: query, albums: [], tracks: [], artists: [])
    }

    func resolve(_ url: URL) async throws -> RemoteResolveResponse {
        try await controller.awaitReady()
        let raw = try await controller.callBridge(
            "window.__flac.metadata(\(jsString(url.absoluteString)))",
            as: LucidaMetadata.self
        )
        // lucida.to wraps every endpoint in a `{success, ...}` envelope.
        // Our bridge only flags transport-level failures; an explicit
        // `success: false` (e.g. region-locked, removed, geo-blocked)
        // would otherwise come back as a track with empty everything.
        if raw.success == false {
            throw StreamerError.unavailable(raw.error ?? "lucida metadata unavailable")
        }
        return raw.toRemote(originalURL: url)
    }

    func getStream(for track: RemoteTrack) async throws -> DownloadStream {
        try await controller.awaitReady()

        guard let trackURL = track.url else {
            throw StreamerError.unsupportedURL(URL(string: "lucida://missing")!)
        }

        // Use the per-track options the UI stashed before enqueueing, or
        // fall back to defaults (Original / metadata / no compat).
        let opts = optionsByTrackID[track.id] ?? .default

        let (handoff, server) = try await runJob(track: track, sourceURL: trackURL, options: opts)

        // Build the same redirect=true URL the website hands to window.open;
        // WKDownload follows the 302 internally and writes to disk.
        let inner = "/api/fetch/request/\(handoff)/download"
        let outer = "https://lucida.to/api/load?url=\(percent(inner))"
            + "&force=\(percent(server))&redirect=true"
        guard let dlURL = URL(string: outer) else {
            throw StreamerError.unavailable("could not build download URL")
        }

        // Set up the writer FIRST and bytes stream eagerly, then start the
        // download. Awaiting `awaitResponse()` blocks until headers arrive,
        // so the DownloadStream we hand back to the coordinator carries the
        // *real* extension and MIME — not a hardcoded "flac" guess that
        // breaks tagging when the source is MP3/AAC.
        let writer = LucidaDownloadWriter()
        let request = URLRequest(url: dlURL)
        let download = await controller.startDownload(request)
        download.delegate = writer
        let info = try await writer.awaitResponse()
        // Drop the per-track option entry now that the download is in flight.
        optionsByTrackID.removeValue(forKey: track.id)
        return writer.downloadStream(using: info)
    }

    // MARK: - Per-track options

    /// Options keyed by `RemoteTrack.id`. The UI calls `setOptions(_:for:)`
    /// just before `DownloadCoordinator.enqueue(_:)`; `getStream` reads and
    /// then removes the entry.
    private var optionsByTrackID: [String: LucidaOptions] = [:]

    func setOptions(_ options: LucidaOptions, for track: RemoteTrack) {
        optionsByTrackID[track.id] = options
    }

    // MARK: - Internals

    private let controller: LucidaWebController
    private let sourceMatcher: SourceMatchService

    init(controller: LucidaWebController, sourceMatcher: SourceMatchService = SourceMatchService()) {
        self.controller = controller
        self.sourceMatcher = sourceMatcher
        super.init()
    }

    /// Run a Lucida job for `track` through to server-side completion.
    /// Spotify links are Lucida's least reliable source — its own Spotify
    /// downloader routinely fails server-side — so for a Spotify track we walk
    /// each `SourceMatchService.Service` in order, and only hand Lucida the
    /// Spotify link once every alternate is unmatched or has failed. If that
    /// fails too, the error says every platform was tried and lists why each
    /// one failed.
    private func runJob(
        track: RemoteTrack, sourceURL: URL, options: LucidaOptions
    ) async throws -> (handoff: String, server: String) {
        guard Self.isSpotify(sourceURL) else {
            return try await attempt(sourceURL, track: track, options: options)
        }
        var reasons: [String] = []
        for service in SourceMatchService.Service.allCases {
            guard let url = await sourceMatcher.url(for: track, on: service) else {
                controller.addLog(.info, "No \(service.rawValue) match for \(track.title)")
                // Worded to avoid PlaylistRebuildCoordinator.isPermanentFailure's
                // "no match" keyword — one missing match shouldn't stop retries
                // when the other platforms failed only transiently.
                reasons.append("\(service.rawValue): track not in catalog search")
                continue
            }
            do {
                return try await attempt(url, track: track, options: options)
            } catch where !(error is CancellationError) {
                reasons.append("\(service.rawValue): \(Self.reason(error))")
            }
        }
        do {
            return try await attempt(sourceURL, track: track, options: options)
        } catch where !(error is CancellationError) {
            reasons.append("Spotify: \(Self.reason(error))")
        }
        let platforms = (SourceMatchService.Service.allCases.map(\.rawValue) + ["Spotify"])
            .joined(separator: ", ")
        throw StreamerError.unavailable(
            "Tried every platform (\(platforms)) and none could download this track. "
            + reasons.joined(separator: " · "))
    }

    /// One source, initiate → poll. Failures are logged to the debug pane
    /// with the source URL so they can be reproduced on lucida.to directly.
    private func attempt(
        _ url: URL, track: RemoteTrack, options: LucidaOptions
    ) async throws -> (handoff: String, server: String) {
        do {
            let (handoff, server) = try await requestJob(url: url, options: options)
            try await waitForCompletion(handoff: handoff, server: server)
            return (handoff, server)
        } catch where !(error is CancellationError) {
            controller.addLog(.error, "\(track.title) via \(url.absoluteString): \(Self.reason(error))")
            throw error
        }
    }

    /// Bridge/transport errors (e.g. "pollRequest HTTP 429") arrive as plain
    /// `Error`s, so they're described too rather than only `StreamerError`s.
    private static func reason(_ error: Error) -> String {
        if case .unavailable(let message)? = error as? StreamerError { return message }
        return error.localizedDescription
    }

    private static func isSpotify(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return host == "open.spotify.com" || host == "spotify.com"
    }

    private func requestJob(
        url: URL, options: LucidaOptions
    ) async throws -> (handoff: String, server: String) {
        let body = LucidaStreamRequest(url: url.absoluteString, options: options)
        let bodyJSON = String(data: try JSONEncoder().encode(body), encoding: .utf8)!

        // Pace job initiations globally so concurrent downloads don't trip
        // Lucida's per-IP rate limiter on job starts.
        await awaitInitiationSlot()

        let initiate = try await controller.callBridge(
            "window.__flac.streamV2(\(bodyJSON), null)",
            as: LucidaStreamInitiateResponse.self
        )

        // Lucida returns `{success:false, error}` (no handoff) when it can't
        // start a job for this URL — e.g. the source has no matching release or
        // the server is busy. Surface that as a clean, per-track failure rather
        // than letting a missing-key decode error bubble up.
        guard let handoff = initiate.handoff, let server = initiate.name else {
            throw StreamerError.unavailable(initiate.error ?? "Lucida couldn't start this download.")
        }
        return (handoff, server)
    }

    /// Repeatedly call `__flac.pollRequest(handoff, server)` until the job
    /// is `completed` or `error`. Lucida's status payload uses a freeform
    /// `message` for in-progress; we just echo the latest one back to the
    /// coordinator via `JobStatus.downloading` (no granular bytes yet).
    private func waitForCompletion(handoff: String, server: String) async throws {
        let deadline = Date().addingTimeInterval(180) // 3 minutes
        while Date() < deadline {
            let res = try await controller.callBridge(
                "window.__flac.pollRequest(\(jsString(handoff)), \(jsString(server)))",
                as: LucidaPollResponse.self
            )
            if res.status == "completed" { return }
            if res.status == "error" {
                throw StreamerError.unavailable(res.failureReason)
            }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        throw StreamerError.unavailable("Lucida job timed out after 3 minutes")
    }

    private func jsString(_ s: String) -> String {
        // JSON encoding of a single string yields a properly quoted JS literal.
        let data = try! JSONEncoder().encode(s)
        return String(data: data, encoding: .utf8)!
    }

    private func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

// MARK: - Wire types

/// Loose decoder for the metadata payload. lucida.to returns a track or
/// album shape mirroring Lucida's `GetByUrlResponse` (Resources/lucida/src/
/// types.ts) on top of a `{success, error?}` envelope. Field availability
/// varies by upstream service so almost everything is optional.
private struct LucidaMetadata: Decodable {
    let success: Bool?
    let error: String?
    let type: String?
    let title: String?
    let artists: [Artist]?
    let album: Album?
    let durationMs: Double?
    let trackNumber: Int?
    let discNumber: Int?
    let isrc: String?
    let url: String?
    let coverArtwork: [Artwork]?
    /// Lucida types.ts uses `releaseDate?: Date` — JSON-encoded as an ISO
    /// string. We don't need full date precision, just the year for tags.
    let releaseDate: String?
    let genres: [String]?
    let tracks: [TrackEntry]?
    /// Playlist owner / curator. Lucida's field name varies by upstream
    /// service; `creator` and `owner` are the two we've observed.
    let creator: String?
    let owner: String?

    struct Artist: Decodable { let name: String?; let url: String?; let pictures: [Artwork]? }
    struct Album: Decodable {
        let title: String?
        /// Lucida's canonical field is `releaseDate`, not `releaseYear`. Some
        /// streamer adapters ship a numeric `releaseYear` for convenience —
        /// accept either.
        let releaseDate: String?
        let releaseYear: Int?
        let trackCount: Int?
        let url: String?
        let coverArtwork: [Artwork]?
    }

    /// Lucida returns artwork two ways depending on the upstream service:
    /// either as `{url, width?, height?}` objects (Qobuz, Tidal) or as bare
    /// URL strings (Amazon Music, some Spotify variants). We accept both.
    struct Artwork: Decodable {
        let url: String?
        let width: Int?
        let height: Int?

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self.url = s; self.width = nil; self.height = nil
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.url    = try c.decodeIfPresent(String.self, forKey: .url)
            self.width  = try c.decodeIfPresent(Int.self,    forKey: .width)
            self.height = try c.decodeIfPresent(Int.self,    forKey: .height)
        }

        private enum CodingKeys: String, CodingKey { case url, width, height }
    }
    struct TrackEntry: Decodable {
        let title: String?
        let artists: [Artist]?
        let durationMs: Double?
        let trackNumber: Int?
        let discNumber: Int?
        let isrc: String?
        let url: String?
        let releaseDate: String?
    }

    /// Pull the year out of an ISO-8601 / partial-ISO date string. Supports
    /// `2024`, `2024-08`, `2024-08-15`, and `2024-08-15T12:34:56Z`.
    static func year(from raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        return Int(raw.prefix(4))
    }

    func toRemote(originalURL: URL) -> RemoteResolveResponse {
        switch type {
        case "album":
            return .album(buildAlbum(originalURL: originalURL))
        case "playlist":
            return .playlist(buildPlaylist(originalURL: originalURL))
        default:
            return .track(buildTrack(originalURL: originalURL))
        }
    }

    private func buildTrack(originalURL: URL) -> RemoteTrack {
        let arts = (artists ?? []).map { a in
            RemoteArtist(
                id: a.name ?? "",
                name: a.name ?? "Unknown Artist",
                url: a.url.flatMap(URL.init(string:)),
                pictureURL: a.pictures?.first?.url.flatMap(URL.init(string:))
            )
        }
        let trackTitle = title ?? originalURL.lastPathComponent
        // For services with no album concept (notably SoundCloud), the
        // metadata comes back with `album = nil`. Rather than write an empty
        // album tag (which the library shows as "Unknown" / "Untitled"),
        // synthesize an album from the track itself: the on-disk album tag
        // becomes the track title, and the library-side grouping shows the
        // track as a single rather than dumping it into a nameless bucket.
        let resolvedAlbum: RemoteAlbumRef
        if let al = album, let albTitle = al.title, !albTitle.isEmpty {
            resolvedAlbum = RemoteAlbumRef(
                id: albTitle,
                title: albTitle,
                url: al.url.flatMap(URL.init(string:)),
                coverArt: (al.coverArtwork ?? []).compactMap(Self.toCover),
                releaseYear: al.releaseYear ?? Self.year(from: al.releaseDate),
                trackCount: al.trackCount
            )
        } else {
            resolvedAlbum = RemoteAlbumRef(
                id: "single:\(originalURL.absoluteString)",
                title: trackTitle,
                url: nil,
                coverArt: (coverArtwork ?? []).compactMap(Self.toCover),
                releaseYear: Self.year(from: releaseDate),
                trackCount: 1
            )
        }
        return RemoteTrack(
            id: originalURL.absoluteString,
            title: trackTitle,
            artists: arts,
            album: resolvedAlbum,
            trackNumber: trackNumber,
            discNumber: discNumber,
            durationSeconds: durationMs.map { $0 / 1000 },
            coverArt: (coverArtwork ?? []).compactMap(Self.toCover),
            url: URL(string: url ?? originalURL.absoluteString) ?? originalURL,
            serviceID: "lucida",
            isLossless: true   // optimistic; lucida prefers lossless when available
        )
    }

    private func buildAlbum(originalURL: URL) -> RemoteAlbum {
        let albumArts = (album?.coverArtwork ?? coverArtwork ?? []).compactMap(Self.toCover)
        let mainArtists = (artists ?? []).map { a in
            RemoteArtist(id: a.name ?? "", name: a.name ?? "Unknown Artist",
                         url: nil, pictureURL: nil)
        }
        let albumTitle = album?.title ?? title ?? originalURL.lastPathComponent
        let albumYear = album?.releaseYear ?? Self.year(from: album?.releaseDate ?? releaseDate)
        let trackList: [RemoteTrack] = (tracks ?? []).enumerated().map { idx, t in
            RemoteTrack(
                id: "\(originalURL.absoluteString)#\(idx)",
                title: t.title ?? "Track \(idx + 1)",
                artists: (t.artists ?? artists ?? []).map { a in
                    RemoteArtist(id: a.name ?? "", name: a.name ?? "Unknown Artist",
                                 url: nil, pictureURL: nil)
                },
                album: RemoteAlbumRef(
                    id: albumTitle, title: albumTitle,
                    url: originalURL, coverArt: albumArts,
                    releaseYear: albumYear, trackCount: album?.trackCount
                ),
                trackNumber: t.trackNumber ?? (idx + 1),
                discNumber: t.discNumber,
                durationSeconds: t.durationMs.map { $0 / 1000 },
                coverArt: albumArts,
                url: URL(string: t.url ?? originalURL.absoluteString) ?? originalURL,
                serviceID: "lucida",
                isLossless: true
            )
        }
        return RemoteAlbum(
            id: originalURL.absoluteString,
            title: albumTitle,
            artists: mainArtists,
            releaseYear: albumYear,
            coverArt: albumArts,
            url: originalURL,
            trackCount: album?.trackCount ?? trackList.count,
            tracks: trackList,
            serviceID: "lucida"
        )
    }

    /// Build a `RemotePlaylist` from a resolved playlist payload. Unlike an
    /// album, playlist tracks span many artists/albums, so each entry keeps its
    /// own service-native URL (the Spotify track URL) — that's what the rebuild
    /// flow matches to another service, and what Lucida falls back to.
    /// Per-entry album metadata is absent, so each track synthesizes a single
    /// album from its own title (same approach as `buildTrack`) rather than
    /// being lumped into one fake "playlist album" folder on disk.
    private func buildPlaylist(originalURL: URL) -> RemotePlaylist {
        let playlistArts = (coverArtwork ?? []).compactMap(Self.toCover)
        let trackList: [RemoteTrack] = (tracks ?? []).enumerated().map { idx, t in
            let entryArtists = (t.artists ?? []).map { a in
                RemoteArtist(id: a.name ?? "", name: a.name ?? "Unknown Artist",
                             url: a.url.flatMap(URL.init(string:)), pictureURL: nil)
            }
            let entryTitle = t.title ?? "Track \(idx + 1)"
            let entryURL = URL(string: t.url ?? originalURL.absoluteString) ?? originalURL
            // Synthesize a single-track album so the on-disk layout is
            // Artist/<title>/NN - Title rather than a nameless bucket.
            let single = RemoteAlbumRef(
                id: "single:\(entryURL.absoluteString)",
                title: entryTitle,
                url: nil,
                coverArt: [],
                releaseYear: Self.year(from: t.releaseDate),
                trackCount: 1
            )
            return RemoteTrack(
                id: "\(originalURL.absoluteString)#\(idx)",
                title: entryTitle,
                artists: entryArtists,
                album: single,
                trackNumber: t.trackNumber,
                discNumber: t.discNumber,
                durationSeconds: t.durationMs.map { $0 / 1000 },
                coverArt: [],
                url: entryURL,
                serviceID: "lucida",
                isLossless: true
            )
        }
        return RemotePlaylist(
            id: originalURL.absoluteString,
            title: title ?? originalURL.lastPathComponent,
            creator: creator ?? owner ?? artists?.first?.name,
            coverArt: playlistArts,
            url: originalURL,
            tracks: trackList,
            serviceID: "lucida"
        )
    }

    private static func toCover(_ a: Artwork) -> RemoteCoverArt? {
        guard let s = a.url, let u = URL(string: s) else { return nil }
        return RemoteCoverArt(url: u, width: a.width, height: a.height)
    }
}

private struct LucidaStreamRequest: Encodable {
    let url: String
    let metadata: Bool
    let compat: Bool
    let `private`: Bool
    let handoff: Bool
    let account: Account
    let upload: Upload
    let downscale: String

    struct Account: Encodable { let id: String; let type: String }
    struct Upload: Encodable { let enabled: Bool; let service: String }

    init(url: String, options: LucidaOptions) {
        self.url        = url
        self.metadata   = options.addMetadata
        self.compat     = options.compatibility
        self.private    = true
        self.handoff    = true
        self.account    = .init(id: options.region, type: "country")
        self.upload     = .init(enabled: false, service: "pixeldrain")
        self.downscale  = options.downscale
    }
}

private struct LucidaStreamInitiateResponse: Decodable {
    let success: Bool?
    /// Optional: absent when Lucida returns an error envelope instead of a job
    /// (handled in `getStream`, which surfaces `error` as a clean failure).
    let handoff: String?
    /// Server name that owns this job; passed back as `force=` to keep
    /// every subsequent call routed to the same backend node.
    let name: String?
    let error: String?
    let skipbo: String?
    let skipboExpiration: Double?
}

private struct LucidaPollResponse: Decodable {
    let success: Bool?
    let status: String?
    let message: String?
    let error: String?

    /// Lucida leaves `message` at the last progress text ("Downloading…")
    /// when a job errors, so prefer `error` and never present a progress
    /// string as the cause.
    var failureReason: String {
        if let error, !error.isEmpty { return error }
        let last = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isProgress = last.isEmpty || last.hasSuffix("…") || last.hasSuffix("...")
        return isProgress
            ? "Lucida's server failed the job\(last.isEmpty ? "" : " during “\(last)”") with no error detail"
            : last
    }
}
