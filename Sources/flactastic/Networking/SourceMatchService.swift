import Foundation

/// Maps a Spotify track to equivalents on services Lucida downloads from
/// more reliably. Lucida's own Spotify downloader routinely fails
/// server-side, so a Spotify link is only ever the last resort.
///
/// Each service is matched through its free, keyless public search API:
///  - Deezer: GET https://api.deezer.com/search (~50 req / 5 s)
///  - Apple Music: GET https://itunes.apple.com/search (~20 req / min)
/// Candidates must agree on title, share an artist, and land within ~6
/// seconds of the Spotify duration — a wrong match is worse than none.
///
/// (This replaced an Odesli / song.link → Amazon Music lookup; Odesli's
/// public API now answers 401 `PUBLIC_API_ACCESS_DEPRECATED`.)
///
/// Best-effort by design: any failure returns `nil` so the caller moves on
/// to the next service.
actor SourceMatchService {
    /// Services to try, in order, before falling back to Spotify itself.
    enum Service: String, CaseIterable, Sendable {
        case deezer = "Deezer"
        case appleMusic = "Apple Music"

        /// Minimum spacing between searches, from each API's published quota.
        var minimumInterval: TimeInterval {
            switch self {
            case .deezer:     return 0.15
            case .appleMusic: return 3.2
            }
        }
    }

    private let session: URLSession
    private var lastRequestAt: [Service: Date] = [:]

    /// Keyed by service + Spotify URL. Caches misses too, so retry rounds in
    /// the playlist rebuild don't re-query for tracks that have no match.
    private var cache: [String: URL?] = [:]

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

    /// `track`'s URL on `service`, or `nil` when there's no confident match.
    /// Called lazily per service, so later services are only searched (and
    /// their tighter quotas only spent) when earlier ones fail.
    func url(for track: RemoteTrack, on service: Service) async -> URL? {
        guard let spotifyURL = track.url else { return nil }
        let key = "\(service.rawValue)|\(spotifyURL.absoluteString)"
        if let cached = cache[key] { return cached }
        let match: URL?
        switch service {
        case .deezer:     match = await deezerURL(for: track)
        case .appleMusic: match = await appleMusicURL(for: track)
        }
        cache[key] = match
        return match
    }

    private func deezerURL(for track: RemoteTrack) async -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: Self.query(for: track)),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let payload = await fetch(components?.url, as: DeezerSearch.self, service: .deezer)
        else { return nil }
        let best = payload.data?.first {
            Self.matches(title: [$0.title, $0.title_short], artist: $0.artist?.name,
                         seconds: $0.duration.map(Double.init), track: track)
        }
        return best?.link.flatMap(URL.init(string:))
    }

    private func appleMusicURL(for track: RemoteTrack) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: Self.query(for: track)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let payload = await fetch(components?.url, as: ITunesSearch.self, service: .appleMusic)
        else { return nil }
        let best = payload.results?.first {
            Self.matches(title: [$0.trackName], artist: $0.artistName,
                         seconds: $0.trackTimeMillis.map { $0 / 1000 }, track: track)
        }
        // Drop iTunes' affiliate `uo` tracking param; keep `?i=<track id>`.
        guard let raw = best?.trackViewUrl, var link = URLComponents(string: raw) else { return nil }
        link.queryItems = link.queryItems?.filter { $0.name == "i" }
        return link.url
    }

    private func fetch<T: Decodable>(_ endpoint: URL?, as: T.Type, service: Service) async -> T? {
        guard let endpoint else { return nil }
        await throttle(service)
        guard let (data, response) = try? await session.data(from: endpoint),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// "<first artist> <bare title>" — "Deacon Blues - Remastered" finds nothing.
    private static func query(for track: RemoteTrack) -> String {
        let artist = track.artists.map(\.name).first { $0 != "Unknown Artist" }
        let title = track.title.components(separatedBy: " - ")[0]
        return ([artist].compactMap { $0 } + [title]).joined(separator: " ")
    }

    private static func matches(
        title candidates: [String?], artist: String?, seconds: Double?, track: RemoteTrack
    ) -> Bool {
        let want = baseTitle(track.title)
        guard candidates.compactMap({ $0 }).contains(where: { baseTitle($0) == want })
        else { return false }
        let artists = track.artists.map(\.name).filter { $0 != "Unknown Artist" }
        if let artist, !artists.isEmpty,
           !artists.contains(where: { normalize($0) == normalize(artist) }) {
            return false
        }
        if let want = track.durationSeconds, let got = seconds, abs(got - want) > 6 {
            return false
        }
        return true
    }

    /// Title with version suffixes dropped — Spotify's "Peg - Remastered" and
    /// Deezer's "Peg (Remastered 1999)" both compare as "peg".
    static func baseTitle(_ s: String) -> String {
        var t = s
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: " (") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: " [") { t = String(t[..<r.lowerBound]) }
        return normalize(t)
    }

    /// Lowercased, diacritic-folded, alphanumerics only — so "Don't Stop
    /// (Remastered)" vs "Dont Stop - Remastered" compare equal.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined()
    }

    private func throttle(_ service: Service) async {
        if let last = lastRequestAt[service] {
            let wait = service.minimumInterval - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lastRequestAt[service] = Date()
    }
}

// MARK: - Wire types

private struct DeezerSearch: Decodable {
    let data: [Track]?
    struct Track: Decodable {
        let title: String?
        let title_short: String?
        let link: String?
        let duration: Int?
        let artist: Artist?
    }
    struct Artist: Decodable { let name: String? }
}

private struct ITunesSearch: Decodable {
    let results: [Track]?
    struct Track: Decodable {
        let trackName: String?
        let artistName: String?
        let trackTimeMillis: Double?
        let trackViewUrl: String?
    }
}
