import Foundation

/// Minimal Deezer public-API client used to fetch artist profile images.
/// No auth, no API key — Deezer's `/search/artist` endpoint is open.
struct DeezerArtist: Sendable, Equatable {
    let id: Int
    let name: String
    /// Best available image URL (`picture_xl` preferred).
    let pictureURL: URL?
}

enum DeezerClientError: Error {
    case invalidQuery
    case badResponse
}

actor DeezerClient {
    static let shared = DeezerClient()

    private let session: URLSession
    /// Polite concurrency cap so we don't hammer Deezer when a large grid scrolls.
    private let semaphore = AsyncSemaphore(limit: 4)

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 20
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    /// Search Deezer for an artist by name. Returns the top result whose
    /// folded name matches the query's folded name, or nil otherwise.
    func searchArtist(name: String) async throws -> DeezerArtist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(encoded)&limit=5") else {
            throw DeezerClientError.invalidQuery
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: try await data(url))
        let needle = ArtistResolver.key(for: trimmed)
        let match = decoded.data.first { ArtistResolver.key(for: $0.name) == needle }
                   ?? decoded.data.first
        guard let match else { return nil }

        let urlString = match.picture_xl ?? match.picture_big ?? match.picture_medium
        let pictureURL = urlString.flatMap { URL(string: $0) }
        return DeezerArtist(id: match.id, name: match.name, pictureURL: pictureURL)
    }

    /// An album on Deezer: its barcode, broad genres and track count.
    struct Album: Sendable {
        let id: Int
        let upc: String?
        let genres: [String]
        let trackCount: Int
    }

    /// Finds an album by artist and title, then fetches its details. Picks
    /// the result whose track count is closest to `trackCount`, so a deluxe
    /// edition isn't mistaken for the standard one.
    func album(artist: String, title: String, trackCount: Int?) async throws -> Album? {
        let q = "artist:\"\(artist)\" album:\"\(title)\""
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(encoded)&limit=5") else { throw DeezerClientError.invalidQuery }
        let hits = try JSONDecoder().decode(AlbumSearch.self, from: try await data(url)).data
        let wanted = ArtistResolver.key(for: title)
        let named = hits.filter { ArtistResolver.key(for: $0.title) == wanted }
        let pool = named.isEmpty ? hits : named
        guard let best = pool.min(by: { abs(($0.nb_tracks ?? 0) - (trackCount ?? 0)) < abs(($1.nb_tracks ?? 0) - (trackCount ?? 0)) }) else { return nil }
        return try await album(id: best.id)
    }

    func album(id: Int) async throws -> Album? {
        guard let url = URL(string: "https://api.deezer.com/album/\(id)") else { throw DeezerClientError.invalidQuery }
        let d = try JSONDecoder().decode(AlbumDetail.self, from: try await data(url))
        guard let albumID = d.id else { return nil }
        return Album(id: albumID, upc: d.upc, genres: d.genres?.data.map(\.name) ?? [], trackCount: d.nb_tracks ?? 0)
    }

    /// A single track: its ISRC and the album it's on.
    func track(artist: String, title: String) async throws -> (isrc: String?, albumID: Int?)? {
        // Deezer's field search (artist:"…" track:"…") finds no tracks, so a
        // plain search, keeping only a hit whose artist and title match.
        let q = "\(artist) \(title)"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=10") else { throw DeezerClientError.invalidQuery }
        let wantArtist = ArtistResolver.key(for: artist), wantTitle = ArtistResolver.key(for: title)
        let hits = try JSONDecoder().decode(TrackSearch.self, from: try await data(url)).data
        guard let hit = hits.first(where: {
            ArtistResolver.key(for: $0.artist?.name ?? "") == wantArtist && ArtistResolver.key(for: $0.title) == wantTitle
        }) else { return nil }
        // Search results leave out the ISRC; the track itself has it.
        guard let detailURL = URL(string: "https://api.deezer.com/track/\(hit.id)") else { return nil }
        let detail = try JSONDecoder().decode(TrackDetail.self, from: try await data(detailURL))
        return (detail.isrc, detail.album?.id ?? hit.album?.id)
    }

    /// An API call: at most four at once here, and within Deezer's shared
    /// rate limit. Everything this client looks up is background work.
    private func data(_ url: URL) async throws -> Data {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        return try await DeezerAPI.get(url, session: session, priority: .background)
    }

    private struct AlbumSearch: Decodable {
        struct Hit: Decodable { let id: Int; let title: String; let nb_tracks: Int? }
        let data: [Hit]
    }
    private struct AlbumDetail: Decodable {
        struct Genres: Decodable { struct G: Decodable { let name: String }; let data: [G] }
        let id: Int?
        let upc: String?
        let nb_tracks: Int?
        let genres: Genres?
    }
    private struct TrackSearch: Decodable {
        struct Hit: Decodable {
            struct A: Decodable { let id: Int }
            struct P: Decodable { let name: String }
            let id: Int
            let title: String
            let album: A?
            let artist: P?
        }
        let data: [Hit]
    }
    private struct TrackDetail: Decodable {
        struct A: Decodable { let id: Int }
        let isrc: String?
        let album: A?
    }

    /// The names of up to 50 artists Deezer lists as related to this one.
    func relatedArtists(id: Int) async throws -> [String] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(id)/related?limit=50") else {
            throw DeezerClientError.invalidQuery
        }
        return try JSONDecoder().decode(RelatedResponse.self, from: try await data(url)).data.map(\.name)
    }

    /// Download raw image bytes for a known URL. Images come from Deezer's
    /// CDN, not the API, so they don't count against its rate limit.
    func downloadImage(url: URL) async throws -> Data {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeezerClientError.badResponse
        }
        return data
    }

    // MARK: - Wire models

    private struct SearchResponse: Decodable {
        let data: [Hit]
    }

    private struct RelatedResponse: Decodable {
        struct Artist: Decodable { let name: String }
        let data: [Artist]
    }

    private struct Hit: Decodable {
        let id: Int
        let name: String
        let picture_medium: String?
        let picture_big: String?
        let picture_xl: String?
    }
}

/// Tiny async semaphore used to throttle concurrent Deezer requests.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.available = limit }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
