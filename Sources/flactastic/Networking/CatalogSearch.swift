import Foundation

/// An album or song found by searching a catalogue, before anything is
/// fetched from Lucida. `link` is a service URL the existing resolve
/// pipeline already understands, so opening or downloading a result is the
/// same as pasting that link.
struct CatalogResult: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case album, ep, single, compilation, track

        var label: String {
            switch self {
            case .album: "Album"
            case .ep: "EP"
            case .single: "Single"
            case .compilation: "Compilation"
            case .track: "Track"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let artist: String
    /// For a track, the album it's on.
    let album: String?
    let coverURL: URL?
    let thumbnailURL: URL?
    let trackCount: Int?
    let durationSeconds: Int?
    let year: Int?
    let isExplicit: Bool
    let link: URL

    var isTrack: Bool { kind == .track }
}

struct CatalogSearchResults: Sendable {
    let query: String
    /// The release most likely wanted; also left out of `albums`.
    let top: CatalogResult?
    let tracks: [CatalogResult]
    let albums: [CatalogResult]

    var isEmpty: Bool { top == nil && tracks.isEmpty && albums.isEmpty }
}

/// A catalogue the Download tab can search. Deezer today; anything that can
/// hand back links Lucida resolves can stand in for it. Where a result
/// downloads from is decided later, by `ReleaseSources`.
protocol CatalogSearching: Sendable {
    var sourceName: String { get }
    func search(_ query: String) async throws -> CatalogSearchResults
}

enum CatalogSearchError: LocalizedError {
    case unreachable
    /// Deezer's rate limit, still hit after waiting and retrying.
    case busy

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Check your connection and try again."
        case .busy: return "Deezer is busy right now. Try again in a few seconds."
        }
    }
}

// MARK: - Deezer

/// Deezer's public catalogue: no account or key. Its releases carry the
/// ISRCs and barcodes that find the same music on Hi-Res services.
actor DeezerCatalogSearch: CatalogSearching {
    static let shared = DeezerCatalogSearch()

    nonisolated let sourceName = "Deezer"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func search(_ query: String) async throws -> CatalogSearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        async let albumHits = get(SearchPage<AlbumHit>.self, "search/album", ["q": q, "limit": "25"])
        async let trackHits = get(SearchPage<TrackHit>.self, "search/track", ["q": q, "limit": "20"])
        let albums = try await albumHits.data ?? []
        let tracks = try await trackHits.data ?? []
        try Task.checkCancellation()

        // Deezer ranks by relevance, which buries new releases. When the
        // search names an artist, the top result is their newest release,
        // and their discography lends years to the grid.
        let needle = ArtistResolver.key(for: q)
        var years: [Int: Int] = [:]
        var top: AlbumHit?
        if let artist = albums.first(where: { ArtistResolver.key(for: $0.artist?.name ?? "") == needle })?.artist {
            let own = (try? await get(SearchPage<AlbumHit>.self, "artist/\(artist.id)/albums", ["limit": "100"]).data) ?? []
            for hit in own { if let year = hit.year { years[hit.id] = year } }
            // A record before a newer one-track single.
            let dated = own.filter { $0.year != nil }
            let records = dated.filter { $0.record_type != "single" }
            top = (records.isEmpty ? dated : records)
                .max { ($0.release_date ?? "") < ($1.release_date ?? "") }
                .map { $0.withArtist(artist) }
        }
        top = top ?? albums.first

        // The top result's own page gives its track count, length and year.
        var topResult: CatalogResult?
        if let top {
            let detail = try? await get(AlbumDetail.self, "album/\(top.id)", [:])
            topResult = result(top, year: detail?.year ?? years[top.id] ?? top.year,
                               trackCount: detail?.nb_tracks, duration: detail?.duration)
        }

        return CatalogSearchResults(
            query: q,
            top: topResult,
            tracks: tracks.compactMap(result),
            albums: albums.filter { $0.id != top?.id }.map { result($0, year: years[$0.id] ?? $0.year) }
        )
    }

    // MARK: Releases

    /// Where a Deezer track sits: what matching it on other services needs.
    struct TrackFacts: Sendable {
        let isrc: String?
        let disc: Int?
        let position: Int?
        let albumID: Int?
    }

    private var factsCache: [Int: TrackFacts] = [:]
    private var upcCache: [Int: String?] = [:]

    /// The numeric ID in a Deezer album or track link
    /// (`deezer.com/album/123`, `deezer.com/us/track/456`).
    nonisolated static func id(in url: URL, kind: String) -> Int? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: kind), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }

    func trackFacts(id: Int) async -> TrackFacts? {
        if let hit = factsCache[id] { return hit }
        guard let track = try? await get(TrackDetail.self, "track/\(id)", [:]) else { return nil }
        let facts = TrackFacts(isrc: track.isrc, disc: track.disk_number, position: track.track_position, albumID: track.album?.id)
        factsCache[id] = facts
        return facts
    }

    /// The Deezer track with this ISRC: the exact recording, no guessing.
    func trackLink(isrc: String) async -> URL? {
        guard let track = try? await get(TrackDetail.self, "track/isrc:\(isrc)", [:]),
              let link = track.link.flatMap(URL.init(string:)),
              let id = Self.id(in: link, kind: "track") else { return nil }
        factsCache[id] = TrackFacts(isrc: track.isrc, disc: track.disk_number, position: track.track_position, albumID: track.album?.id)
        return link
    }

    /// The album's barcode, which other catalogues index releases by.
    func albumUPC(id: Int) async -> String? {
        if let hit = upcCache[id] { return hit }
        let upc = try? await get(AlbumFull.self, "album/\(id)", [:]).upc
        upcCache[id] = upc
        return upc
    }

    /// A Deezer album or track link read straight from Deezer's API, so it
    /// opens even when Lucida can't reach Deezer. Nil for other links.
    func release(_ url: URL) async throws -> RemoteResolveResponse? {
        if let id = Self.id(in: url, kind: "album") {
            async let albumCall = get(AlbumFull.self, "album/\(id)", [:])
            async let tracksCall = get(SearchPage<AlbumTrack>.self, "album/\(id)/tracks", ["limit": "500"])
            let album = try await albumCall
            let entries = try await tracksCall.data ?? []
            upcCache[id] = album.upc
            return .album(remoteAlbum(album, id: id, entries: entries))
        }
        if let id = Self.id(in: url, kind: "track") {
            let track = try await get(TrackDetail.self, "track/\(id)", [:])
            factsCache[id] = TrackFacts(isrc: track.isrc, disc: track.disk_number, position: track.track_position, albumID: track.album?.id)
            guard let albumID = track.album?.id else { return nil }
            let album = try await get(AlbumFull.self, "album/\(albumID)", [:])
            let ref = albumRef(album, id: albumID, discTotal: nil)
            return .track(RemoteTrack(
                id: track.link ?? url.absoluteString, title: track.title,
                artists: artists(track.contributors, fallback: track.artist?.name),
                album: ref, trackNumber: track.track_position, discNumber: track.disk_number,
                durationSeconds: track.duration.map(Double.init), coverArt: ref.coverArt,
                url: track.link.flatMap(URL.init(string:)) ?? url, serviceID: "lucida", isLossless: true,
                isrc: track.isrc
            ))
        }
        return nil
    }

    private func remoteAlbum(_ album: AlbumFull, id: Int, entries: [AlbumTrack]) -> RemoteAlbum {
        let discTotal = entries.compactMap(\.disk_number).max()
        let ref = albumRef(album, id: id, discTotal: discTotal)
        let main = artists(album.contributors, fallback: album.artist?.name)
        let tracks = entries.enumerated().map { index, entry in
            RemoteTrack(
                id: entry.link ?? "https://www.deezer.com/track/\(entry.id)", title: entry.title,
                artists: entry.artist.map { [RemoteArtist(id: $0.name, name: $0.name, url: nil, pictureURL: nil)] } ?? main,
                album: ref, trackNumber: entry.track_position ?? index + 1, discNumber: entry.disk_number,
                durationSeconds: entry.duration.map(Double.init), coverArt: ref.coverArt,
                url: URL(string: entry.link ?? "https://www.deezer.com/track/\(entry.id)"),
                serviceID: "lucida", isLossless: true, isrc: entry.isrc
            )
        }
        return RemoteAlbum(
            id: "https://www.deezer.com/album/\(id)", title: album.title, artists: main,
            releaseYear: album.year, coverArt: ref.coverArt, url: URL(string: "https://www.deezer.com/album/\(id)"),
            trackCount: album.nb_tracks ?? tracks.count, tracks: tracks, serviceID: "lucida"
        )
    }

    private func albumRef(_ album: AlbumFull, id: Int, discTotal: Int?) -> RemoteAlbumRef {
        let covers = [album.cover_xl, album.cover_big].compactMap { $0.flatMap(URL.init(string:)) }
        return RemoteAlbumRef(
            id: album.title, title: album.title, url: URL(string: "https://www.deezer.com/album/\(id)"),
            coverArt: covers.enumerated().map { RemoteCoverArt(url: $1, width: $0 == 0 ? 1000 : 500, height: $0 == 0 ? 1000 : 500) },
            releaseYear: album.year, trackCount: album.nb_tracks,
            label: ReleaseLabel.from(label: album.label, copyright: nil), discTotal: discTotal
        )
    }

    private func artists(_ contributors: [ArtistRef]?, fallback: String?) -> [RemoteArtist] {
        let names = contributors?.map(\.name) ?? []
        let list = names.isEmpty ? [fallback ?? "Unknown Artist"] : names
        return list.map { RemoteArtist(id: $0, name: $0, url: nil, pictureURL: nil) }
    }

    // MARK: Mapping

    private func result(_ hit: AlbumHit, year: Int?, trackCount: Int? = nil, duration: Int? = nil) -> CatalogResult {
        let kind: CatalogResult.Kind = switch hit.record_type {
        case "ep": .ep
        case "single": .single
        case "compile": .compilation
        default: .album
        }
        return CatalogResult(
            id: "deezer:album:\(hit.id)", kind: kind, title: hit.title,
            artist: hit.artist?.name ?? "Unknown Artist", album: nil,
            coverURL: hit.cover_xl.flatMap(URL.init(string:)) ?? hit.cover_big.flatMap(URL.init(string:)),
            thumbnailURL: hit.cover_medium.flatMap(URL.init(string:)),
            trackCount: trackCount ?? hit.nb_tracks, durationSeconds: duration, year: year,
            isExplicit: hit.explicit_lyrics ?? false,
            link: URL(string: "https://www.deezer.com/album/\(hit.id)")!
        )
    }

    private func result(_ hit: TrackHit) -> CatalogResult? {
        guard hit.readable != false else { return nil }
        return CatalogResult(
            id: "deezer:track:\(hit.id)", kind: .track, title: hit.title,
            artist: hit.artist?.name ?? "Unknown Artist", album: hit.album?.title,
            coverURL: hit.album?.cover_xl.flatMap(URL.init(string:)),
            thumbnailURL: hit.album?.cover_small.flatMap(URL.init(string:)),
            trackCount: nil, durationSeconds: hit.duration, year: nil,
            isExplicit: hit.explicit_lyrics ?? false,
            link: URL(string: "https://www.deezer.com/track/\(hit.id)")!
        )
    }

    // MARK: Transport

    private func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, _ query: [String: String]) async throws -> T {
        var components = URLComponents(string: "https://api.deezer.com/\(path)")!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let data: Data
        do {
            data = try await DeezerAPI.get(components.url!, session: session, priority: .interactive)
        } catch let failure as DeezerAPI.Failure where failure.isRateLimit || failure.httpStatus == 429 {
            throw CatalogSearchError.busy
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CatalogSearchError.unreachable
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Wire models

    private struct SearchPage<Hit: Decodable & Sendable>: Decodable, Sendable {
        let data: [Hit]?
    }

    private struct ArtistRef: Decodable, Sendable {
        let id: Int
        let name: String
    }

    private struct AlbumHit: Decodable, Sendable {
        let id: Int
        let title: String
        let cover_medium: String?
        let cover_big: String?
        let cover_xl: String?
        let nb_tracks: Int?
        let record_type: String?
        let explicit_lyrics: Bool?
        let release_date: String?
        var artist: ArtistRef?

        var year: Int? { release_date.flatMap { Int($0.prefix(4)) } }

        /// An artist's own album list leaves the artist out of each entry.
        func withArtist(_ artist: ArtistRef) -> AlbumHit {
            var copy = self
            copy.artist = self.artist ?? artist
            return copy
        }
    }

    private struct AlbumDetail: Decodable, Sendable {
        let nb_tracks: Int?
        let duration: Int?
        let release_date: String?

        var year: Int? { release_date.flatMap { Int($0.prefix(4)) } }
    }

    private struct AlbumFull: Decodable, Sendable {
        let title: String
        let upc: String?
        let label: String?
        let release_date: String?
        let nb_tracks: Int?
        let cover_big: String?
        let cover_xl: String?
        let artist: ArtistRef?
        let contributors: [ArtistRef]?

        var year: Int? { release_date.flatMap { Int($0.prefix(4)) } }
    }

    private struct AlbumTrack: Decodable, Sendable {
        let id: Int
        let title: String
        let link: String?
        let duration: Int?
        let isrc: String?
        let disk_number: Int?
        let track_position: Int?
        let artist: ArtistRef?
    }

    private struct TrackDetail: Decodable, Sendable {
        struct AlbumID: Decodable, Sendable { let id: Int }
        let title: String
        let link: String?
        let duration: Int?
        let isrc: String?
        let disk_number: Int?
        let track_position: Int?
        let artist: ArtistRef?
        let contributors: [ArtistRef]?
        let album: AlbumID?
    }

    private struct TrackHit: Decodable, Sendable {
        struct AlbumRef: Decodable, Sendable {
            let title: String?
            let cover_small: String?
            let cover_xl: String?
        }
        let id: Int
        let title: String
        let duration: Int?
        let explicit_lyrics: Bool?
        let readable: Bool?
        let artist: ArtistRef?
        let album: AlbumRef?
    }
}

// MARK: - What's already in the library

/// Answers "do I already have this?" everywhere on the Download tab. A
/// track uses `LibraryMatchIndex`, the same rule a download uses to skip
/// what's already there, so a track marked In Library is one a download
/// would skip. An album matches by artist and title, with case, accents,
/// punctuation and an " - EP" / " - Single" suffix ignored. Built once per
/// library change, off the main thread.
struct LibraryOwnership: Sendable {
    private var albums = Set<String>()
    private let tracks: LibraryMatchIndex

    init(tracks library: [Track], resolver: ArtistResolver) {
        tracks = LibraryMatchIndex(library)
        for track in library {
            guard let album = track.album else { continue }
            let albumKey = Self.titleKey(album)
            for artist in resolver.split(track.albumArtist ?? track.artist) {
                albums.insert(ArtistResolver.key(for: artist) + "|" + albumKey)
            }
        }
    }

    /// Owns nothing: used until the real one is worked out.
    init() {
        tracks = LibraryMatchIndex([])
    }

    @MainActor
    init(library: LibraryStore) {
        self.init(tracks: library.tracks, resolver: library.makeArtistResolver())
    }

    func owns(_ result: CatalogResult) -> Bool {
        if result.isTrack {
            return owns(RemoteTrack(
                id: result.id, title: result.title,
                artists: [RemoteArtist(id: result.artist, name: result.artist, url: nil, pictureURL: nil)],
                album: result.album.map { RemoteAlbumRef(id: $0, title: $0, url: nil, coverArt: [], releaseYear: nil, trackCount: nil) },
                trackNumber: nil, discNumber: nil, durationSeconds: result.durationSeconds.map(Double.init),
                coverArt: [], url: result.link, serviceID: "lucida", isLossless: true))
        }
        return albums.contains(ArtistResolver.key(for: result.artist) + "|" + Self.titleKey(result.title))
    }

    func owns(_ track: RemoteTrack) -> Bool {
        tracks.match(track) != nil
    }

    static func titleKey(_ raw: String) -> String {
        var title = raw
        for suffix in [" - EP", " - Single", " EP"] where title.lowercased().hasSuffix(suffix.lowercased()) {
            title.removeLast(suffix.count)
            break
        }
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
