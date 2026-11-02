import Foundation

/// A service Lucida downloads from, ranked by the best quality it delivers.
/// Qobuz, Tidal and Amazon reach Hi-Res; Deezer is CD-quality FLAC; the
/// rest are lossy or uncertain, and Spotify is always the last resort.
enum SourceService: Int, Comparable, Sendable {
    case qobuz, tidal, amazon, deezer, appleMusic, soundcloud, youtube, spotify, other

    init(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("qobuz.com") { self = .qobuz }
        else if host.hasSuffix("tidal.com") { self = .tidal }
        else if host.hasPrefix("music.amazon.") { self = .amazon }
        else if host.hasSuffix("deezer.com") { self = .deezer }
        else if host == "music.apple.com" { self = .appleMusic }
        else if host.hasSuffix("soundcloud.com") { self = .soundcloud }
        else if host == "music.youtube.com" { self = .youtube }
        else if host.hasSuffix("spotify.com") { self = .spotify }
        else { self = .other }
    }

    var name: String {
        switch self {
        case .qobuz: "Qobuz"
        case .tidal: "Tidal"
        case .amazon: "Amazon Music"
        case .deezer: "Deezer"
        case .appleMusic: "Apple Music"
        case .soundcloud: "SoundCloud"
        case .youtube: "YouTube Music"
        case .spotify: "Spotify"
        case .other: "Lucida"
        }
    }

    var isHiRes: Bool { self <= .amazon }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Finds every copy of a track Lucida could download, best quality first.
///
/// The track is anchored on Deezer (its own link, its ISRC, or a confident
/// search match), which gives its ISRC, disc and position and its album's barcode.
/// The barcode then finds the same release elsewhere:
///  - MusicBrainz's links for the release (Qobuz, Tidal, Amazon when
///    someone has added them). These are album links, so Lucida lists the
///    album once and the track is picked out by ISRC, then position, then title.
///  - Apple's catalogue lookup by barcode, which links each track directly.
///
/// Every lookup is best-effort and cached; a miss just leaves that service
/// out. The original link always stays in the list.
actor ReleaseSources {
    /// Lists an album through Lucida: its tracks, or nil when that failed.
    typealias Expand = @Sendable (URL) async -> [RemoteTrack]?

    private let deezer: DeezerCatalogSearch
    private let matcher: SourceMatchService
    private let session: URLSession

    private var releaseLinks: [String: [URL]] = [:]
    private var appleTracks: [String: [AppleTrack]] = [:]
    private var lastMusicBrainzCall = Date.distantPast

    init(deezer: DeezerCatalogSearch = .shared, matcher: SourceMatchService) {
        self.deezer = deezer
        self.matcher = matcher
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Download links for `track`, best first, `original` among them.
    func candidates(for track: RemoteTrack, original: URL, expand: Expand) async -> [URL] {
        var found: [URL] = [original]

        // Anchor on Deezer: the link itself, the recording's ISRC, or a
        // confident title match.
        var deezerTrack: URL?
        if SourceService(original) == .deezer, DeezerCatalogSearch.id(in: original, kind: "track") != nil {
            deezerTrack = original
        } else if let isrc = track.isrc, let match = await deezer.trackLink(isrc: isrc) {
            deezerTrack = match
            found.append(match)
        } else if let match = await matcher.url(for: track, on: .deezer) {
            deezerTrack = match
            found.append(match)
        }

        if let deezerTrack,
           let trackID = DeezerCatalogSearch.id(in: deezerTrack, kind: "track"),
           let facts = await deezer.trackFacts(id: trackID),
           let albumID = facts.albumID,
           let upc = await deezer.albumUPC(id: albumID) {
            // Hi-Res copies of the release, narrowed to this track.
            for album in await links(forBarcode: upc) where SourceService(album).isHiRes {
                guard let tracks = await expand(album),
                      let match = Self.pick(from: tracks, isrc: facts.isrc ?? track.isrc, disc: facts.disc,
                                            position: facts.position, title: track.title),
                      let url = match.url else { continue }
                found.append(url)
            }
            if let apple = await appleTrack(barcode: upc, disc: facts.disc, position: facts.position) {
                found.append(apple)
            }
        }
        if !found.contains(where: { SourceService($0) == .appleMusic }),
           let apple = await matcher.url(for: track, on: .appleMusic) {
            found.append(apple)
        }

        // Best first; the order found breaks ties, so the original leads its tier.
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.absoluteString).inserted }
        return unique.enumerated()
            .sorted { (SourceService($0.element), $0.offset) < (SourceService($1.element), $1.offset) }
            .map(\.element)
    }

    /// The track in a listed album: ISRC first, then disc and position, then title.
    static func pick(from tracks: [RemoteTrack], isrc: String?, disc: Int?, position: Int?, title: String) -> RemoteTrack? {
        if let isrc, let hit = tracks.first(where: { $0.isrc?.caseInsensitiveCompare(isrc) == .orderedSame }) {
            return hit
        }
        if let position, let hit = tracks.first(where: { $0.trackNumber == position && ($0.discNumber ?? 1) == (disc ?? 1) }) {
            return hit
        }
        let want = SourceMatchService.baseTitle(title)
        return tracks.first { SourceMatchService.baseTitle($0.title) == want }
    }

    // MARK: MusicBrainz

    /// The release's streaming links from MusicBrainz. MusicBrainz asks for
    /// at most one request a second and an identifying user agent.
    private func links(forBarcode upc: String) async -> [URL] {
        if let hit = releaseLinks[upc] { return hit }
        var links: [URL] = []
        if let search: MBSearch = await musicBrainz("release", ["query": "barcode:\(upc)"]),
           let release = search.releases?.first,
           let detail: MBRelease = await musicBrainz("release/\(release.id)", ["inc": "url-rels"]) {
            links = (detail.relations ?? []).compactMap { $0.url?.resource }.compactMap(URL.init(string:))
        }
        releaseLinks[upc] = links
        return links
    }

    private func musicBrainz<T: Decodable & Sendable>(_ path: String, _ query: [String: String]) async -> T? {
        let wait = 1.1 - Date().timeIntervalSince(lastMusicBrainzCall)
        lastMusicBrainzCall = Date().addingTimeInterval(max(0, wait))
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)")!
        components.queryItems = (query.merging(["fmt": "json"]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("FLACtastic/1.0 ( https://github.com/patronsaynt/flactastic )", forHTTPHeaderField: "User-Agent")
        return await fetch(request)
    }

    // MARK: Apple

    private func appleTrack(barcode upc: String, disc: Int?, position: Int?) async -> URL? {
        guard let position else { return nil }
        let tracks: [AppleTrack]
        if let hit = appleTracks[upc] {
            tracks = hit
        } else {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [URLQueryItem(name: "upc", value: upc), URLQueryItem(name: "entity", value: "song"),
                                     URLQueryItem(name: "limit", value: "200")]
            let lookup: AppleLookup? = await fetch(URLRequest(url: components.url!))
            tracks = (lookup?.results ?? []).filter { $0.wrapperType == "track" }
            appleTracks[upc] = tracks
        }
        let match = tracks.first { $0.trackNumber == position && ($0.discNumber ?? 1) == (disc ?? 1) }
        // Drop iTunes' affiliate `uo` parameter; keep `?i=<track id>`.
        guard let raw = match?.trackViewUrl, var link = URLComponents(string: raw) else { return nil }
        link.queryItems = link.queryItems?.filter { $0.name == "i" }
        return link.url
    }

    private func fetch<T: Decodable & Sendable>(_ request: URLRequest) async -> T? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Wire models

    private struct MBSearch: Decodable, Sendable {
        struct Release: Decodable, Sendable { let id: String }
        let releases: [Release]?
    }

    private struct MBRelease: Decodable, Sendable {
        struct Relation: Decodable, Sendable {
            struct Link: Decodable, Sendable { let resource: String }
            let url: Link?
        }
        let relations: [Relation]?
    }

    private struct AppleLookup: Decodable, Sendable {
        let results: [AppleTrack]?
    }

    private struct AppleTrack: Decodable, Sendable {
        let wrapperType: String?
        let trackNumber: Int?
        let discNumber: Int?
        let trackViewUrl: String?
    }
}
