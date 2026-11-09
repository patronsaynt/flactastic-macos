import Foundation

/// Shared transport for every call to Deezer's public API.
///
/// Deezer allows about 50 requests per 5 seconds from one address, across
/// every endpoint, so all callers share one `DeezerRateLimiter`. Going over
/// doesn't produce an HTTP error: Deezer answers 200 with
/// `{"error": {"type": "Exception", "message": "Quota limit exceeded", "code": 4}}`
/// in place of the expected body, which decoders then misread as missing data
/// or "no results". `get` turns that body into a `DeezerAPI.Failure`, and on a
/// quota error pauses everyone for a window and retries once.
enum DeezerAPI {
    enum Priority: Sendable {
        /// Something the person is waiting on: a search they typed.
        case interactive
        /// Bulk lookups: artist images, genres, related artists, matching.
        case background
    }

    /// An error Deezer reported in the body of an otherwise successful reply,
    /// or a non-2xx status (`code` 0, `httpStatus` set).
    struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        var code: Int
        var message: String
        var httpStatus: Int? = nil

        /// 4: "Quota limit exceeded". 700: "Service busy".
        var isRateLimit: Bool { code == 4 || code == 700 }

        var description: String {
            if let httpStatus { return "Deezer HTTP \(httpStatus)" }
            return "Deezer error \(code): \(message)"
        }
    }

    static let limiter = DeezerRateLimiter()

    /// The error object in a Deezer reply body, if it is one.
    static func failure(in data: Data) -> Failure? {
        struct Envelope: Decodable {
            struct Body: Decodable { let code: Int?; let message: String? }
            let error: Body?
        }
        guard let body = (try? JSONDecoder().decode(Envelope.self, from: data))?.error else { return nil }
        return Failure(code: body.code ?? -1, message: body.message ?? "Unknown error")
    }

    /// GETs `request` within the shared rate limit and returns the body,
    /// throwing `Failure` for a Deezer error body or a non-2xx status. A
    /// rate-limit error pauses all Deezer traffic for one window and is
    /// retried once.
    static func get(
        _ request: URLRequest,
        session: URLSession,
        priority: Priority,
        limiter: DeezerRateLimiter = DeezerAPI.limiter
    ) async throws -> Data {
        var attempt = 0
        while true {
            await limiter.acquire(priority)
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 429, attempt == 0 {
                    await limiter.backOff()
                    attempt += 1
                    continue
                }
                throw Failure(code: 0, message: "HTTP \(http.statusCode)", httpStatus: http.statusCode)
            }
            if let failure = failure(in: data) {
                if failure.isRateLimit, attempt == 0 {
                    await limiter.backOff()
                    attempt += 1
                    continue
                }
                throw failure
            }
            return data
        }
    }

    static func get(_ url: URL, session: URLSession, priority: Priority) async throws -> Data {
        try await get(URLRequest(url: url), session: session, priority: priority)
    }
}

/// A sliding-window limit on requests to Deezer. Background work may use at
/// most `backgroundLimit` of each window, so a search the person types still
/// goes straight through while hundreds of artist images are being fetched.
actor DeezerRateLimiter {
    let window: TimeInterval
    let backgroundLimit: Int
    let interactiveLimit: Int

    private var sent: [Date] = []
    private var pausedUntil: Date = .distantPast
    private let now: @Sendable () -> Date

    init(
        window: TimeInterval = 5,
        backgroundLimit: Int = 30,
        interactiveLimit: Int = 45,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.window = window
        self.backgroundLimit = backgroundLimit
        self.interactiveLimit = interactiveLimit
        self.now = now
    }

    /// Waits until a request of this priority fits in the window, then
    /// counts it.
    func acquire(_ priority: DeezerAPI.Priority) async {
        let limit = priority == .interactive ? interactiveLimit : backgroundLimit
        while true {
            let current = now()
            sent.removeAll { current.timeIntervalSince($0) >= window }
            if current >= pausedUntil, sent.count < limit {
                sent.append(current)
                return
            }
            // Sleep until the pause ends or the oldest request leaves the window.
            let windowFrees = sent.count >= limit ? sent[sent.count - limit].addingTimeInterval(window) : current
            let wake = max(pausedUntil, windowFrees)
            let delay = max(0.05, wake.timeIntervalSince(current))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
        }
    }

    /// Deezer said we're over its limit: send nothing for one full window.
    func backOff() {
        pausedUntil = max(pausedUntil, now().addingTimeInterval(window))
    }

    /// Requests counted in the current window (for tests).
    var recentCount: Int {
        let current = now()
        return sent.filter { current.timeIntervalSince($0) < window }.count
    }
}
