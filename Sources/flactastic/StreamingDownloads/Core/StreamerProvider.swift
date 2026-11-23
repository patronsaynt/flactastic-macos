import Foundation

/// Swift analogue of Lucida's `Streamer` interface (Resources/lucida/src/types.ts).
/// Each streaming service ships an actor (or actor-isolated class) conforming to
/// this; `StreamerRegistry` routes URLs and search queries to the right one.
protocol StreamerProvider: Sendable {
    /// Stable namespace id for this service ("qobuz", "deezer", "soundcloud").
    /// Used in `RemoteTrack.serviceID` so DownloadCoordinator can route the
    /// `getStream` call back to the same provider that produced the track.
    var serviceID: String { get }

    /// Human-facing service name shown in the UI ("Qobuz", "Deezer").
    var displayName: String { get }

    /// Hostnames this provider claims for URL routing — matched case-
    /// insensitively against `URL.host`.
    var hostnames: [String] { get }

    /// True iff the user has supplied enough credentials for the provider to
    /// attempt requests. The UI gates the service picker on this.
    var isConfigured: Bool { get async }

    /// Attempt login / token refresh using the credentials the provider was
    /// constructed with. Throws on auth failure. Idempotent.
    func login() async throws

    /// Search the service catalog. `limit` is a per-bucket hint.
    func search(_ query: String, limit: Int) async throws -> StreamerSearchResults

    /// Resolve a service URL to either a track, album, playlist, or artist.
    func resolve(_ url: URL) async throws -> RemoteResolveResponse

    /// Fetch the byte stream for a specific track. The track must have been
    /// produced by *this* provider (matching `serviceID`).
    func getStream(for track: RemoteTrack) async throws -> DownloadStream

    /// Lightweight account probe used by Settings → "Test login" UI.
    func accountInfo() async throws -> StreamerAccount
}

enum StreamerError: LocalizedError {
    case notConfigured(service: String)
    case notLoggedIn(service: String)
    case unsupportedURL(URL)
    case unsupportedFormat(String)
    case authenticationFailed(service: String, reason: String?)
    case http(status: Int, body: String?)
    case decoding(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s):
            return "\(s) is not configured. Add credentials in Settings → Streaming."
        case .notLoggedIn(let s):
            return "\(s) is not logged in."
        case .unsupportedURL(let u):
            // Keeps "Unsupported": playlist rebuilds treat it as permanent.
            return "Unsupported link: FLACtastic can't download from \(u.host ?? u.absoluteString)."
        case .unsupportedFormat(let f):
            return "Unsupported audio format: \(f) files can't be saved."
        case .authenticationFailed(let s, let reason):
            return "Couldn't sign in to \(s)\(reason.map { ": \($0)" } ?? ".")"
        case .http(let status, _):
            return "The download service returned an error (HTTP \(status)). Try again."
        case .decoding:
            return "Lucida sent a reply FLACtastic couldn't read. Try again."
        case .unavailable(let msg):
            return msg
        }
    }
}
