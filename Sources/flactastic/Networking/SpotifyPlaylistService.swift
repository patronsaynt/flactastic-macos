import Foundation

/// Resolves a public Spotify playlist into a `RemotePlaylist`.
///
/// Two strategies, picked automatically:
///  - **Web API** (full tracklist, no cap): given a user OAuth bearer token
///    from `SpotifyAuthController` (account linking), paginate
///    `api.spotify.com` for the complete tracklist.
///  - **Embed fallback** (no auth needed): scrape the no-auth
///    `open.spotify.com/embed/playlist/<id>` page's `__NEXT_DATA__` JSON. Works
///    for any public playlist but Spotify caps that preview at 100 tracks —
///    used for the paste-a-link flow when the user isn't connected.
///
/// Why not Lucida: lucida.to's `/api/fetch/metadata` works for tracks/albums but
/// fails ("Load failed") on Spotify playlists.
///
/// An `actor` so calls are safely serialized across concurrent resolves.
actor SpotifyPlaylistService {

    /// The embed preview caps at this many entries.
    static let trackCap = 100

    enum ServiceError: LocalizedError {
        case notASpotifyPlaylist
        case fetchFailed(Int)
        case parseFailed
        case authFailed(Int)
        /// Non-2xx with Spotify's own error message extracted from the body.
        case apiError(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notASpotifyPlaylist:
                return "That doesn't look like a Spotify playlist link."
            case .fetchFailed(let code):
                return "Couldn't reach Spotify (HTTP \(code))."
            case .parseFailed:
                return "Couldn't read the playlist from Spotify. It may be private."
            case .authFailed(let code):
                return "Spotify rejected the request (HTTP \(code)). Try reconnecting your Spotify account in Settings."
            case .apiError(let code, let message):
                return "Spotify refused the request (HTTP \(code)): \(message)"
            }
        }
    }

    struct Result: Sendable {
        let playlist: RemotePlaylist
        /// True when the tracklist hit the 100-entry embed cap (the real
        /// playlist has more tracks than we could see). Always false for the
        /// Web API path, which fetches everything.
        let wasTruncated: Bool
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Entry point

    /// Resolve via the no-auth embed preview, capped at 100 tracks. Used for
    /// the paste-a-link flow when the user isn't connected — connect the
    /// Spotify account (`resolve(_:userToken:)`) for full, uncapped tracklists.
    func resolve(_ url: URL) async throws -> Result {
        guard let playlistID = Self.playlistID(from: url) else {
            throw ServiceError.notASpotifyPlaylist
        }
        return try await resolveViaEmbed(playlistID: playlistID, sourceURL: url)
    }

    /// Resolve using a user OAuth bearer token (from `SpotifyAuthController`).
    /// Works for the user's private *and* public playlists, uncapped. No embed
    /// fallback: a 401 means the token went stale (caller reconnects), a 404
    /// means the playlist isn't accessible.
    func resolve(_ url: URL, userToken: String) async throws -> Result {
        guard let playlistID = Self.playlistID(from: url) else {
            throw ServiceError.notASpotifyPlaylist
        }
        return try await resolveViaAPI(playlistID: playlistID, sourceURL: url, token: userToken)
    }

    /// Resolve the user's saved ("Liked Songs") tracks via `/v1/me/tracks`.
    /// Uncapped, paginated 50 at a time. No embed fallback — this endpoint
    /// requires a user OAuth token.
    func resolveLikedSongs(userToken token: String) async throws -> Result {
        var tracks: [RemoteTrack] = []
        var cover: [RemoteCoverArt] = []
        var offset = 0
        let limit = 50
        while true {
            let fields = "next,items(track(name,duration_ms,is_local,external_urls(spotify),external_ids(isrc),artists(name),album(images)))"
            let page = try await apiGet(
                "https://api.spotify.com/v1/me/tracks?offset=\(offset)&limit=\(limit)&fields=\(fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fields)",
                token: token, as: APISavedTracksPage.self)
            for entry in page.items ?? [] {
                if cover.isEmpty, let images = entry.track?.album?.images {
                    cover = images.compactMap { img -> RemoteCoverArt? in
                        guard let s = img.url, let u = URL(string: s) else { return nil }
                        return RemoteCoverArt(url: u, width: img.width, height: img.height)
                    }
                }
                if let track = Self.remoteTrack(from: entry.track, index: tracks.count) {
                    tracks.append(track)
                }
            }
            let got = page.items?.count ?? 0
            if page.next == nil || got < limit { break }
            offset += limit
        }

        let sourceURL = URL(string: "https://open.spotify.com/collection/tracks")!
        let playlist = RemotePlaylist(
            id: sourceURL.absoluteString,
            title: "Liked Songs",
            creator: nil,
            coverArt: cover,
            url: sourceURL,
            tracks: tracks,
            serviceID: "lucida"
        )
        return Result(playlist: playlist, wasTruncated: false)
    }

    // MARK: - Web API path

    /// Resolve via the Web API given an already-minted user OAuth bearer
    /// token (from `SpotifyAuthController`'s account linking).
    private func resolveViaAPI(
        playlistID: String,
        sourceURL: URL,
        token: String
    ) async throws -> Result {
        // Playlist header: name, owner, cover.
        let headerFields = "name,owner(display_name),images"
        let header = try await apiGet(
            "https://api.spotify.com/v1/playlists/\(playlistID)?fields=\(headerFields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? headerFields)",
            token: token, as: APIPlaylistHeader.self)

        // Tracks, paginated 100 at a time. We use the modern `/items` endpoint
        // (track under `item`); Spotify now returns 403 Forbidden on the legacy
        // `/tracks` endpoint for many apps.
        var tracks: [RemoteTrack] = []
        var offset = 0
        let limit = 100
        while true {
            let fields = "next,items(item(name,duration_ms,is_local,external_urls(spotify),external_ids(isrc),artists(name)))"
            let page = try await apiGet(
                "https://api.spotify.com/v1/playlists/\(playlistID)/items?offset=\(offset)&limit=\(limit)&fields=\(fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fields)",
                token: token, as: APITrackPage.self)
            for entry in page.items ?? [] {
                if let track = Self.remoteTrack(from: entry.trackPayload, index: tracks.count) {
                    tracks.append(track)
                }
            }
            let got = page.items?.count ?? 0
            if page.next == nil || got < limit { break }
            offset += limit
        }

        let cover = (header.images ?? []).compactMap { img -> RemoteCoverArt? in
            guard let s = img.url, let u = URL(string: s) else { return nil }
            return RemoteCoverArt(url: u, width: img.width, height: img.height)
        }

        let playlist = RemotePlaylist(
            id: sourceURL.absoluteString,
            title: header.name ?? "Playlist",
            creator: header.owner?.display_name,
            coverArt: cover,
            url: sourceURL,
            tracks: tracks,
            serviceID: "lucida"
        )
        return Result(playlist: playlist, wasTruncated: false)
    }

    private func apiGet<T: Decodable>(_ urlString: String, token: String, as: T.Type) async throws -> T {
        guard let url = URL(string: urlString) else { throw ServiceError.parseFailed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.fetchFailed(-1) }
        if http.statusCode == 401 { throw ServiceError.authFailed(401) }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.apiError(code: http.statusCode, message: Self.spotifyMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.parseFailed
        }
    }

    /// Pull Spotify's `{ "error": { "status", "message" } }` text out of an
    /// error body, falling back to a raw snippet.
    private static func spotifyMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String, !message.isEmpty {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "no details" : String(raw.prefix(200))
    }

    private static func remoteTrack(from t: APITrack?, index: Int) -> RemoteTrack? {
        guard let t, t.is_local != true,
              let spotifyURL = t.external_urls?.spotify.flatMap(URL.init(string:)) else { return nil }
        let artists = (t.artists ?? []).compactMap { $0.name }.map {
            RemoteArtist(id: $0, name: $0, url: nil, pictureURL: nil)
        }
        return RemoteTrack(
            id: spotifyURL.absoluteString,
            title: t.name ?? "Track \(index + 1)",
            artists: artists.isEmpty
                ? [RemoteArtist(id: "unknown", name: "Unknown Artist", url: nil, pictureURL: nil)]
                : artists,
            album: nil,
            trackNumber: nil,
            discNumber: nil,
            durationSeconds: t.duration_ms.map { $0 / 1000 },
            coverArt: [],
            url: spotifyURL,
            serviceID: "lucida",
            isLossless: true,
            // Finds the exact recording on other services, rather than a
            // title match.
            isrc: t.external_ids?.isrc
        )
    }

    // MARK: - Embed path

    private func resolveViaEmbed(playlistID: String, sourceURL: URL) async throws -> Result {
        let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(playlistID)")!
        var request = URLRequest(url: embedURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.fetchFailed(-1) }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.fetchFailed(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8),
              let json = Self.extractNextData(from: html) else {
            throw ServiceError.parseFailed
        }
        return try Self.buildEmbedResult(from: json, sourceURL: sourceURL)
    }

    // MARK: - Parsing (shared + embed)

    /// Pull the playlist id out of an https URL or a `spotify:playlist:` URI.
    static func playlistID(from url: URL) -> String? {
        let id: String
        if url.scheme == "spotify" {
            let parts = url.absoluteString.split(separator: ":")
            guard parts.count == 3, parts[1] == "playlist" else { return nil }
            id = String(parts[2].prefix { $0 != "?" })
        } else {
            guard let host = url.host?.lowercased(),
                  host == "open.spotify.com" || host == "spotify.com" else { return nil }
            let comps = url.pathComponents.filter { $0 != "/" }
            guard let idx = comps.firstIndex(of: "playlist"), idx + 1 < comps.count else { return nil }
            id = comps[idx + 1]
        }
        // Spotify IDs are base62; anything else would be spliced into API paths.
        return !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? id : nil
    }

    private static func extractNextData(from html: String) -> [String: Any]? {
        let pattern = #"<script id="__NEXT_DATA__" type="application/json">(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let jsonString = String(html[range])
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func buildEmbedResult(from next: [String: Any], sourceURL: URL) throws -> Result {
        guard let entity = (next["props"] as? [String: Any])?["pageProps"] as? [String: Any],
              let state = entity["state"] as? [String: Any],
              let dataObj = state["data"] as? [String: Any],
              let e = dataObj["entity"] as? [String: Any] else {
            throw ServiceError.parseFailed
        }

        let title = (e["name"] as? String) ?? (e["title"] as? String) ?? "Playlist"
        let creator = e["subtitle"] as? String
        let cover = coverArt(from: e["coverArt"])

        let rawTracks = (e["trackList"] as? [[String: Any]]) ?? []
        let wasTruncated = rawTracks.count >= trackCap

        let tracks: [RemoteTrack] = rawTracks.enumerated().compactMap { idx, t in
            guard let uri = t["uri"] as? String, let trackURL = trackURL(fromURI: uri) else { return nil }
            let trackTitle = (t["title"] as? String) ?? "Track \(idx + 1)"
            let subtitle = (t["subtitle"] as? String) ?? ""
            let artists = subtitle.components(separatedBy: ", ").filter { !$0.isEmpty }
                .map { RemoteArtist(id: $0, name: $0, url: nil, pictureURL: nil) }
            let durationMs = (t["duration"] as? Double) ?? (t["duration"] as? Int).map(Double.init)
            return RemoteTrack(
                id: trackURL.absoluteString,
                title: trackTitle,
                artists: artists.isEmpty
                    ? [RemoteArtist(id: "unknown", name: "Unknown Artist", url: nil, pictureURL: nil)]
                    : artists,
                album: nil,
                trackNumber: nil,
                discNumber: nil,
                durationSeconds: durationMs.map { $0 / 1000 },
                coverArt: [],
                url: trackURL,
                serviceID: "lucida",
                isLossless: true
            )
        }

        let playlist = RemotePlaylist(
            id: sourceURL.absoluteString,
            title: title,
            creator: creator,
            coverArt: cover,
            url: sourceURL,
            tracks: tracks,
            serviceID: "lucida"
        )
        return Result(playlist: playlist, wasTruncated: wasTruncated)
    }

    private static func coverArt(from raw: Any?) -> [RemoteCoverArt] {
        guard let dict = raw as? [String: Any],
              let sources = dict["sources"] as? [[String: Any]] else { return [] }
        return sources.compactMap { src in
            guard let urlString = src["url"] as? String, let u = URL(string: urlString) else { return nil }
            let w = (src["width"] as? Int) ?? (src["width"] as? Double).map(Int.init)
            let h = (src["height"] as? Int) ?? (src["height"] as? Double).map(Int.init)
            return RemoteCoverArt(url: u, width: w, height: h)
        }
    }

    private static func trackURL(fromURI uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[1] == "track" else { return nil }
        return URL(string: "https://open.spotify.com/track/\(parts[2])")
    }
}

// MARK: - Web API wire types

private struct APIPlaylistHeader: Decodable {
    let name: String?
    let owner: Owner?
    let images: [Image]?
    struct Owner: Decodable { let display_name: String? }
    struct Image: Decodable { let url: String?; let width: Int?; let height: Int? }
}

private struct APITrackPage: Decodable {
    let items: [Item]?
    let next: String?
    struct Item: Decodable {
        // The `/items` endpoint nests the track under `item`; the legacy
        // `/tracks` endpoint used `track`. Accept either.
        let item: APITrack?
        let track: APITrack?
    }
}

private extension APITrackPage.Item {
    /// The track payload regardless of which endpoint shape returned it.
    var trackPayload: APITrack? { item ?? track }
}

private struct APITrack: Decodable {
    let name: String?
    let duration_ms: Double?
    let is_local: Bool?
    let external_urls: ExternalURLs?
    let external_ids: ExternalIDs?
    let artists: [Artist]?
    let album: Album?
    struct ExternalURLs: Decodable { let spotify: String? }
    struct ExternalIDs: Decodable { let isrc: String? }
    struct Artist: Decodable { let name: String? }
    struct Album: Decodable { let images: [Image]? }
    struct Image: Decodable { let url: String?; let width: Int?; let height: Int? }
}

private struct APISavedTracksPage: Decodable {
    let items: [Item]?
    let next: String?
    struct Item: Decodable { let track: APITrack? }
}
