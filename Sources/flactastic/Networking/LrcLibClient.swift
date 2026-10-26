import Foundation

/// Minimal lrclib.net client. Free, no API key — lrclib is the de-facto
/// public lyrics database used by Plexamp, Lollypop, Strawberry, etc.
/// Endpoint: GET https://lrclib.net/api/get?artist_name=...&track_name=...
struct LrcLibResponse: Decodable, Sendable {
    let id: Int?
    let plainLyrics: String?
    let syncedLyrics: String?
    let instrumental: Bool?
}

enum LrcLibClientError: Error {
    case invalidQuery
    case badResponse(Int)
}

actor LrcLibClient {
    static let shared = LrcLibClient()

    private let session: URLSession
    /// Polite concurrency cap so we don't burst lrclib on rapid track skips.
    private let semaphore = AsyncSemaphore(limit: 4)

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetch lyrics for a track. Returns `nil` on a 404 (no match);
    /// throws `badResponse` for any other non-2xx status.
    func fetchLyrics(
        artist: String,
        title: String,
        album: String?,
        duration: TimeInterval?
    ) async throws -> LrcLibResponse? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedTitle.isEmpty else {
            throw LrcLibClientError.invalidQuery
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: trimmedArtist),
            URLQueryItem(name: "track_name", value: trimmedTitle),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw LrcLibClientError.invalidQuery }

        var request = URLRequest(url: url)
        // lrclib's docs request a User-Agent that identifies the client.
        request.setValue("FLACtastic (https://github.com/patronsaynt/flactastic)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let (data, response) = try await sendWithRetry(request)
        guard let http = response as? HTTPURLResponse else {
            throw LrcLibClientError.badResponse(-1)
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw LrcLibClientError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(LrcLibResponse.self, from: data)
    }

    /// Transient transport failures that are worth a second attempt on a
    /// fresh connection. `secureConnectionFailed` (-1200) is the common one:
    /// a TLS handshake that lost the race, not a real trust problem — a
    /// genuine bad certificate surfaces as `serverCertificate*` instead and
    /// is deliberately absent here so we never retry past a trust failure.
    private static let retryableCodes: Set<URLError.Code> = [
        .secureConnectionFailed,
        .networkConnectionLost,
        .timedOut,
        .cannotConnectToHost,
    ]

    /// HTTP statuses that mean "busy, try again" rather than anything about
    /// the track. lrclib sits behind Cloudflare and answers 503 (sometimes
    /// 502/504) when overloaded and 429 when rate limiting, usually with a
    /// `Retry-After` header. A missing track is a 404, never one of these.
    private static let retryableStatuses: Set<Int> = [429, 502, 503, 504]

    /// Longest `Retry-After` we'll honor inline. The fetcher holds a
    /// semaphore slot while we wait, so anything longer is left to its
    /// error cooldown instead.
    private static let maxRetryAfter: TimeInterval = 5

    /// Issue the request, retrying transient transport errors and busy-server
    /// statuses with a short exponential backoff. Caps at `maxAttempts` so a
    /// genuinely unreachable host still fails fast rather than stalling the
    /// fetcher's semaphore.
    private func sendWithRetry(
        _ request: URLRequest,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        var attempt = 1
        while true {
            let delay: TimeInterval
            do {
                let (data, response) = try await session.data(for: request)
                guard attempt < maxAttempts,
                      let http = response as? HTTPURLResponse,
                      Self.retryableStatuses.contains(http.statusCode) else {
                    return (data, response)
                }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                if let retryAfter, retryAfter > Self.maxRetryAfter { return (data, response) }
                delay = retryAfter ?? Self.backoff(attempt: attempt, base: 1)
            } catch let error as URLError
                where Self.retryableCodes.contains(error.code) && attempt < maxAttempts {
                delay = Self.backoff(attempt: attempt, base: 0.25)
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    /// `base`, then `2 × base`. Jittered so a batch of tracks that all failed
    /// together doesn't retry in lockstep.
    private static func backoff(attempt: Int, base: TimeInterval) -> TimeInterval {
        base * pow(2.0, Double(attempt - 1)) + Double.random(in: 0...0.1)
    }
}
