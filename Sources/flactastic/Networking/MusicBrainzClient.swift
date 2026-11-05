import Foundation

/// MusicBrainz's public web service, for genres. No key, but two rules it
/// enforces: every request names the app and a contact (the User-Agent), and
/// no more than one request a second. Requests here go out one at a time,
/// 1.1s apart, whichever caller made them; the most urgent waiting request
/// (a playing track over an import over a library scan) goes next.
actor MusicBrainzClient {
    static let shared = MusicBrainzClient()

    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "FLACtastic/\(version) ( https://github.com/patronsaynt/flactastic-macos )"
    }()
    private static let spacing: TimeInterval = 1.1

    enum Urgency: Int, Comparable, Sendable {
        case scan, importing, playing
        static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
    }

    struct Genre: Sendable, Equatable {
        let name: String
        let votes: Int
    }

    /// What a barcode, ISRC or name search found.
    struct Match: Sendable {
        let releaseGroupID: String
        let artistIDs: [String]
        /// Free-form tags carried in the search result (not curated genres).
        let tags: [Genre]
    }

    private let session: URLSession
    private var lastRequest = Date.distantPast
    private var waiting: [(urgency: Urgency, order: Int, go: CheckedContinuation<Void, Never>)] = []
    private var busy = false
    private var order = 0

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "application/json"]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Lookups

    /// The release with this barcode (UPC/EAN), if MusicBrainz has it.
    func release(barcode: String, urgency: Urgency) async throws -> Match? {
        let json = try await get("release/", ["query": "barcode:\(barcode)", "limit": "1"], urgency: urgency)
        guard let r = (json["releases"] as? [[String: Any]])?.first, (r["score"] as? Int ?? 0) >= 90 else { return nil }
        return Self.match(release: r)
    }

    /// The album by name and artist, accepted only on a near-certain match.
    func releaseGroup(title: String, artist: String, urgency: Urgency) async throws -> Match? {
        let q = "releasegroup:\"\(Self.escape(title))\" AND artist:\"\(Self.escape(artist))\""
        let json = try await get("release-group/", ["query": q, "limit": "1"], urgency: urgency)
        guard let g = (json["release-groups"] as? [[String: Any]])?.first,
              (g["score"] as? Int ?? 0) >= 95, let id = g["id"] as? String else { return nil }
        return Match(releaseGroupID: id, artistIDs: Self.artistIDs(g["artist-credit"]), tags: Self.genres(g["tags"]))
    }

    /// The recording with this ISRC, and the album it first appeared on.
    func recording(isrc: String, urgency: Urgency) async throws -> Match? {
        let json = try await get("recording/", ["query": "isrc:\(isrc)", "limit": "1"], urgency: urgency)
        guard let rec = (json["recordings"] as? [[String: Any]])?.first,
              let release = (rec["releases"] as? [[String: Any]])?.first,
              let group = release["release-group"] as? [String: Any],
              let id = group["id"] as? String else { return nil }
        return Match(releaseGroupID: id, artistIDs: Self.artistIDs(rec["artist-credit"]), tags: Self.genres(rec["tags"]))
    }

    /// Curated genres voted onto an album.
    func releaseGroupGenres(_ id: String, urgency: Urgency) async throws -> [Genre] {
        Self.genres(try await get("release-group/\(id)", ["inc": "genres"], urgency: urgency)["genres"])
    }

    /// Curated genres voted onto an artist.
    func artistGenres(_ id: String, urgency: Urgency) async throws -> [Genre] {
        Self.genres(try await get("artist/\(id)", ["inc": "genres"], urgency: urgency)["genres"])
    }

    /// Every genre name MusicBrainz recognises, to tell real genres apart
    /// from other tags ("seen live", "united states").
    func allGenres() async throws -> Set<String> {
        let url = URL(string: "https://musicbrainz.org/ws/2/genre/all?fmt=txt")!
        let data = try await fetch(url, urgency: .scan)
        let text = String(decoding: data, as: UTF8.self)
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    // MARK: Requests

    private func get(_ path: String, _ params: [String: String], urgency: Urgency) async throws -> [String: Any] {
        var parts = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)")!
        parts.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "fmt", value: "json")]
        let data = try await fetch(parts.url!, urgency: urgency)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// One request at a time, 1.1s apart; a 503 (MusicBrainz asking to slow
    /// down) waits and tries again, twice.
    private func fetch(_ url: URL, urgency: Urgency) async throws -> Data {
        for attempt in 0..<3 {
            await take(urgency)
            let wait = Self.spacing - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            lastRequest = Date()
            let result: (Data, URLResponse)
            do { result = try await session.data(from: url) } catch { release(); throw error }
            release()
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 503 { try? await Task.sleep(for: .seconds(2 << attempt)); continue }
            guard (200..<300).contains(status) else { throw DeezerClientError.badResponse }
            return result.0
        }
        throw DeezerClientError.badResponse
    }

    private func take(_ urgency: Urgency) async {
        if !busy { busy = true; return }
        order += 1
        let mine = order
        await withCheckedContinuation { go in waiting.append((urgency, mine, go)) }
    }

    private func release() {
        guard let next = waiting.indices.max(by: {
            (waiting[$0].urgency, -waiting[$0].order) < (waiting[$1].urgency, -waiting[$1].order)
        }) else { busy = false; return }
        waiting.remove(at: next).go.resume()
    }

    // MARK: Parsing

    private static func match(release r: [String: Any]) -> Match? {
        guard let group = r["release-group"] as? [String: Any], let id = group["id"] as? String else { return nil }
        return Match(releaseGroupID: id, artistIDs: artistIDs(r["artist-credit"]), tags: genres(r["tags"]))
    }

    private static func artistIDs(_ credit: Any?) -> [String] {
        ((credit as? [[String: Any]]) ?? []).compactMap { ($0["artist"] as? [String: Any])?["id"] as? String }
    }

    private static func genres(_ list: Any?) -> [Genre] {
        ((list as? [[String: Any]]) ?? []).compactMap { g in
            guard let name = g["name"] as? String else { return nil }
            return Genre(name: name, votes: g["count"] as? Int ?? 1)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
