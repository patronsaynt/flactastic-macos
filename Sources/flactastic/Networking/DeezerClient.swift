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

        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeezerClientError.badResponse
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let needle = ArtistResolver.key(for: trimmed)
        let match = decoded.data.first { ArtistResolver.key(for: $0.name) == needle }
                   ?? decoded.data.first
        guard let match else { return nil }

        let urlString = match.picture_xl ?? match.picture_big ?? match.picture_medium
        let pictureURL = urlString.flatMap { URL(string: $0) }
        return DeezerArtist(id: match.id, name: match.name, pictureURL: pictureURL)
    }

    /// The names of up to 50 artists Deezer lists as related to this one.
    func relatedArtists(id: Int) async throws -> [String] {
        guard let url = URL(string: "https://api.deezer.com/artist/\(id)/related?limit=50") else {
            throw DeezerClientError.invalidQuery
        }
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeezerClientError.badResponse
        }
        return try JSONDecoder().decode(RelatedResponse.self, from: data).data.map(\.name)
    }

    /// Download raw image bytes for a known URL.
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
