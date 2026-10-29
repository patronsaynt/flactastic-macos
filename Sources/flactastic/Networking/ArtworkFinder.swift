import Foundation

/// A cover found online for Find Online in the album and track editors.
struct ArtworkCandidate: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable {
        case apple = "Apple Music"
        case deezer = "Deezer"
        case coverArtArchive = "Cover Art Archive"
    }

    let id: String
    let source: Source
    let title: String
    let artist: String
    let year: Int?
    /// A small image for the results grid.
    let thumbnailURL: URL
    /// The largest the source offers.
    let fullURL: URL
    /// Its size in pixels, when the source says (Apple and Deezer do).
    let pixelSize: Int?
}

/// Finds album covers online. Apple's public iTunes Search API comes first:
/// its covers are the label-supplied masters and come up to 3000 × 3000
/// (the same source the Apple Music Artwork Finder web tool uses). Deezer
/// (1000 × 1000) and the Cover Art Archive (community scans, any size) fill
/// in what Apple doesn't carry. None need an account or a key.
actor ArtworkFinder {
    static let shared = ArtworkFinder()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    /// Every source searched at once; Apple's results first, then Deezer's,
    /// then the archive's. A source that fails is left out rather than
    /// failing the search.
    func search(album: String, artist: String) async -> [ArtworkCandidate] {
        let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        async let apple = (try? searchApple(term: term)) ?? []
        async let deezer = (try? searchDeezer(term: term)) ?? []
        async let archive = (try? searchArchive(album: album, artist: artist)) ?? []
        return await apple + deezer + archive
    }

    /// The full-size image. Apple's is asked for at 3000 px, then 1400 px
    /// for the few covers that don't come that large.
    func download(_ candidate: ArtworkCandidate) async throws -> Data {
        if candidate.source == .apple, let smaller = Self.appleArtworkURL(candidate.fullURL.absoluteString, size: 1400) {
            do { return try await fetch(candidate.fullURL) } catch { return try await fetch(smaller) }
        }
        return try await fetch(candidate.fullURL)
    }

    /// Apple's artwork URLs end in a size such as `100x100bb.jpg`; any other
    /// size can be asked for in its place.
    static func appleArtworkURL(_ url: String, size: Int) -> URL? {
        guard let range = url.range(of: #"\d+x\d+[a-z]*(-\d+)?\.(jpg|png|webp)$"#, options: .regularExpression) else { return nil }
        return URL(string: url.replacingCharacters(in: range, with: "\(size)x\(size)bb.jpg"))
    }

    // MARK: - Sources

    private func searchApple(term: String) async throws -> [ArtworkCandidate] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "album"), .init(name: "limit", value: "12")]
        struct Response: Decodable { let results: [Hit] }
        struct Hit: Decodable {
            let collectionId: Int
            let collectionName: String
            let artistName: String
            let artworkUrl100: String?
            let releaseDate: String?
        }
        let response: Response = try await json(c.url!)
        return response.results.compactMap { hit in
            guard let art = hit.artworkUrl100,
                  let thumb = Self.appleArtworkURL(art, size: 400),
                  let full = Self.appleArtworkURL(art, size: 3000) else { return nil }
            return ArtworkCandidate(
                id: "apple:\(hit.collectionId)", source: .apple, title: hit.collectionName, artist: hit.artistName,
                year: hit.releaseDate.flatMap { Int($0.prefix(4)) }, thumbnailURL: thumb, fullURL: full, pixelSize: 3000
            )
        }
    }

    private func searchDeezer(term: String) async throws -> [ArtworkCandidate] {
        var c = URLComponents(string: "https://api.deezer.com/search/album")!
        c.queryItems = [.init(name: "q", value: term), .init(name: "limit", value: "6")]
        struct Response: Decodable { let data: [Hit] }
        struct Hit: Decodable {
            struct Artist: Decodable { let name: String }
            let id: Int
            let title: String
            let artist: Artist
            let cover_medium: String?
            let cover_xl: String?
        }
        let response: Response = try await json(c.url!)
        return response.data.compactMap { hit in
            guard let xl = hit.cover_xl.flatMap(URL.init(string:)),
                  let thumb = (hit.cover_medium ?? hit.cover_xl).flatMap(URL.init(string:)) else { return nil }
            return ArtworkCandidate(id: "deezer:\(hit.id)", source: .deezer, title: hit.title, artist: hit.artist.name,
                                    year: nil, thumbnailURL: thumb, fullURL: xl, pixelSize: 1000)
        }
    }

    /// MusicBrainz finds the release groups; the archive holds their covers.
    private func searchArchive(album: String, artist: String) async throws -> [ArtworkCandidate] {
        guard !album.isEmpty else { return [] }
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" }
        var query = "releasegroup:\(quoted(album))"
        if !artist.isEmpty { query += " AND artist:\(quoted(artist))" }
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        c.queryItems = [.init(name: "query", value: query), .init(name: "fmt", value: "json"), .init(name: "limit", value: "3")]
        struct Groups: Decodable {
            struct Group: Decodable {
                struct Credit: Decodable { let name: String }
                let id: String
                let title: String
                let firstReleaseDate: String?
                let artistCredit: [Credit]?
                enum CodingKeys: String, CodingKey {
                    case id, title
                    case firstReleaseDate = "first-release-date"
                    case artistCredit = "artist-credit"
                }
            }
            let groups: [Group]
            enum CodingKeys: String, CodingKey { case groups = "release-groups" }
        }
        let groups: Groups = try await json(c.url!)
        // One cover per release group: the archive's front image for it.
        return groups.groups.prefix(3).map { g in
            ArtworkCandidate(
                id: "caa:\(g.id)", source: .coverArtArchive, title: g.title,
                artist: g.artistCredit?.map(\.name).joined(separator: ", ") ?? artist,
                year: g.firstReleaseDate.flatMap { Int($0.prefix(4)) },
                thumbnailURL: URL(string: "https://coverartarchive.org/release-group/\(g.id)/front-500")!,
                fullURL: URL(string: "https://coverartarchive.org/release-group/\(g.id)/front")!,
                pixelSize: nil
            )
        }
    }

    // MARK: - Networking

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        // MusicBrainz asks every client to say who it is.
        r.setValue("FLACtastic (https://github.com/patronsaynt/flactastic)", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func json<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(for: request(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
