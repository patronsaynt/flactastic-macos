import Foundation
import Observation
import AuthenticationServices
import CryptoKit
import AppKit

/// Owns the Spotify *user* login (Authorization Code + PKCE) so FLACtastic can
/// list and download a user's own private playlists. Public, no-login playlist
/// resolves still go through `SpotifyPlaylistService`'s embed / Client-Credentials
/// path — this controller only handles the connected-account experience.
///
/// PKCE means there is no client secret in the app; the embedded `clientID` is
/// not sensitive. Tokens are persisted in `UserDefaults` (see `Store` below).
///
/// ## Developer setup
/// Create an app at developer.spotify.com → Dashboard, paste its Client ID into
/// `clientID` below, and under "Redirect URIs" add exactly
/// `flactastic://spotify-callback`. Spotify apps start in Development Mode, which
/// caps access to 25 users you add by email under "User Management" until Spotify
/// grants extended quota. No client secret is needed for PKCE.
@Observable
@MainActor
final class SpotifyAuthController {

    // MARK: - Configuration

    /// FLACtastic's Spotify app Client ID. Not a secret (PKCE public client).
    /// Replace the placeholder with the real Client ID to enable login.
    private static let clientID = "d4b4f9bd568c45a1a89c597a2792f53a"
    private static let redirectURI = "flactastic://spotify-callback"
    /// Bare scheme handed to `ASWebAuthenticationSession`, which intercepts the
    /// redirect itself (no Info.plist URL-type registration required on macOS).
    private static let callbackScheme = "flactastic"
    private static let scopes = "playlist-read-private playlist-read-collaborative user-library-read"

    private static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "REPLACE_WITH_FLACTASTIC_SPOTIFY_CLIENT_ID"
    }

    /// Token persistence. Stored in `UserDefaults` (the app isn't sandboxed and
    /// already keeps its other Spotify credentials here) rather than the system
    /// Keychain: a Keychain item's ACL is bound to the app's exact code
    /// signature, so every rebuild / unsigned run triggers an inescapable
    /// "wants to use your confidential information" prompt loop. UserDefaults
    /// avoids that entirely. The refresh token is local to this user account
    /// and can be revoked anytime from the user's Spotify account settings.
    private enum Store {
        static let refresh = "flactastic.spotify.refreshToken"
        static let access  = "flactastic.spotify.accessToken"
        static let expiry  = "flactastic.spotify.tokenExpiry"
        static let name    = "flactastic.spotify.displayName"
        static func get(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
        static func set(_ value: String, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
        static func delete(_ key: String) { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Public state

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(displayName: String)
    }

    struct PlaylistSummary: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let owner: String?
        let trackCount: Int
        let coverArtURL: URL?
        /// `open.spotify.com/playlist/<id>` — feeds the resolve pipeline.
        let externalURL: URL
    }

    /// Sentinel id marking the synthetic "Liked Songs" entry — it isn't a real
    /// playlist, so it's resolved via `/v1/me/tracks` instead of
    /// `/v1/playlists/<id>`.
    static let likedSongsID = "__liked_songs__"

    /// A synthetic playlist card for the user's saved tracks. Not fetched from
    /// `/v1/me/playlists` — Spotify doesn't expose Liked Songs there.
    static let likedSongsSummary = PlaylistSummary(
        id: likedSongsID,
        name: "Liked Songs",
        owner: nil,
        trackCount: -1,
        coverArtURL: nil,
        externalURL: URL(string: "https://open.spotify.com/collection/tracks")!
    )

    enum AuthError: LocalizedError {
        case notConfigured
        case notConnected
        case reconnectRequired
        case cancelled
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "FLACtastic isn't set up for Spotify login yet. Paste a public playlist link below instead."
            case .notConnected:
                return "Connect your Spotify account first."
            case .reconnectRequired:
                return "Your Spotify session expired. Reconnect to continue."
            case .cancelled:
                return "Login cancelled."
            case .network(let message):
                return message
            }
        }
    }

    private(set) var state: ConnectionState = .disconnected
    private(set) var playlists: [PlaylistSummary] = []

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Private state

    private let session: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?

    // Retained for the duration of an in-flight auth session.
    private var presenter: WebAuthPresenter?
    private var webAuthSession: ASWebAuthenticationSession?
    private var pendingState: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Lifecycle

    /// Called at launch: if a refresh token is on disk, show as connected
    /// (using the cached display name immediately) and verify via `/v1/me`.
    func restore() async {
        guard Self.isConfigured, let refresh = Store.get(Store.refresh) else { return }
        refreshToken = refresh
        accessToken = Store.get(Store.access)
        if let expiryString = Store.get(Store.expiry),
           let epoch = TimeInterval(expiryString) {
            expiresAt = Date(timeIntervalSince1970: epoch)
        }
        // Optimistic: surface the cached name before any network call.
        if let cachedName = Store.get(Store.name) {
            state = .connected(displayName: cachedName)
        } else {
            state = .connecting
        }
        do {
            let name = try await fetchDisplayName()
            state = .connected(displayName: name)
            await loadPlaylists()
        } catch {
            // Couldn't validate (expired refresh token, offline). If we have a
            // cached name keep showing connected so a later action can retry;
            // otherwise fall back to disconnected.
            if case .connected = state { return }
            state = .disconnected
        }
    }

    // MARK: - Connect / disconnect

    func connect() async {
        guard Self.isConfigured else {
            state = .disconnected
            return
        }
        state = .connecting
        do {
            let verifier = Self.makeCodeVerifier()
            let challenge = Self.codeChallenge(for: verifier)
            let authState = UUID().uuidString
            pendingState = authState

            let callbackURL = try await runAuthSession(
                url: authorizeURL(challenge: challenge, state: authState))

            guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw AuthError.network("Spotify didn't return an authorization code.")
            }
            let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value
            guard returnedState == pendingState else {
                throw AuthError.network("Login state mismatch — please try again.")
            }

            let token = try await exchangeCode(code, verifier: verifier)
            applyTokens(token)

            let name = try await fetchDisplayName()
            Store.set(name, Store.name)
            state = .connected(displayName: name)
            await loadPlaylists()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            state = .disconnected
        } catch is AuthError {
            state = .disconnected
        } catch {
            state = .disconnected
        }
        webAuthSession = nil
        presenter = nil
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        playlists = []
        state = .disconnected
        Store.delete(Store.refresh)
        Store.delete(Store.access)
        Store.delete(Store.expiry)
        Store.delete(Store.name)
    }

    // MARK: - Token access

    /// A valid bearer token, refreshing proactively when near expiry. Throws
    /// `.reconnectRequired` when the refresh token is no longer accepted.
    func validAccessToken() async throws -> String {
        guard refreshToken != nil else { throw AuthError.notConnected }
        if let token = accessToken, let expiry = expiresAt,
           expiry.timeIntervalSinceNow > 60 {
            return token
        }
        let token = try await refreshTokens()
        applyTokens(token)
        return token.access_token
    }

    // MARK: - API: profile + playlists

    private func fetchDisplayName() async throws -> String {
        let me = try await apiGet("https://api.spotify.com/v1/me", as: APIMe.self)
        return me.display_name ?? me.id ?? "Spotify"
    }

    func loadPlaylists() async {
        var collected: [PlaylistSummary] = []
        var url: String? = "https://api.spotify.com/v1/me/playlists?limit=50&offset=0"
        do {
            while let next = url {
                let page = try await apiGet(next, as: APIPlaylistPage.self)
                for item in page.items ?? [] {
                    guard let id = item.id, let name = item.name,
                          let external = item.external_urls?.spotify.flatMap(URL.init(string:)) else { continue }
                    let cover = item.images?.first?.url.flatMap(URL.init(string:))
                    collected.append(PlaylistSummary(
                        id: id, name: name,
                        owner: item.owner?.display_name,
                        // Spotify returns the count under `items` (newer) or
                        // `tracks` (older) depending on the response.
                        trackCount: item.items?.total ?? item.tracks?.total ?? 0,
                        coverArtURL: cover,
                        externalURL: external))
                }
                url = page.next
            }
            playlists = collected
        } catch {
            // Leave whatever we already have; the UI surfaces load failures
            // when it has nothing to show.
        }
    }

    // MARK: - PKCE helpers

    private static func makeCodeVerifier() -> String {
        let bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func authorizeURL(challenge: String, state: String) -> URL {
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            // Always show the consent screen so reconnecting re-grants the
            // current scopes (avoids a stale, under-scoped prior authorization).
            URLQueryItem(name: "show_dialog", value: "true"),
        ]
        return comps.url!
    }

    private func runAuthSession(url: URL) async throws -> URL {
        // Capture the anchor window now, on the main actor — the presenter is
        // queried by AuthenticationServices and must not reach into NSApp from
        // a background thread.
        let presenter = WebAuthPresenter(anchor: NSApp.keyWindow ?? NSApp.windows.first)
        self.presenter = presenter
        return try await withCheckedThrowingContinuation { continuation in
            // IMPORTANT: this completion handler is invoked by
            // ASWebAuthenticationSession on a background XPC queue. It must be
            // `@Sendable` (non-isolated) — if it inherited this method's
            // @MainActor isolation, Swift's executor check would trap (SIGTRAP)
            // when it runs off the main thread. Resuming a continuation is
            // thread-safe, so no main-actor hop is needed here.
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: Self.callbackScheme
            ) { @Sendable callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.cancelled)
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            if !session.start() {
                continuation.resume(throwing: AuthError.network("Couldn't start the Spotify login window."))
            }
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(_ code: String, verifier: String) async throws -> TokenResponse {
        try await tokenRequest(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": verifier,
        ])
    }

    private func refreshTokens() async throws -> TokenResponse {
        guard let refresh = refreshToken else { throw AuthError.notConnected }
        do {
            return try await tokenRequest(form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Self.clientID,
            ])
        } catch {
            // Refresh token rejected — force a reconnect.
            disconnect()
            throw AuthError.reconnectRequired
        }
    }

    private func tokenRequest(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network("No response from Spotify.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.network("Spotify token request failed (HTTP \(http.statusCode)).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func applyTokens(_ token: TokenResponse) {
        accessToken = token.access_token
        if let refresh = token.refresh_token { refreshToken = refresh }
        let expiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
        expiresAt = expiry

        Store.set(token.access_token, Store.access)
        Store.set(String(expiry.timeIntervalSince1970), Store.expiry)
        if let refresh = refreshToken {
            Store.set(refresh, Store.refresh)
        }
    }

    // MARK: - Authenticated GET

    private func apiGet<T: Decodable>(_ urlString: String, as: T.Type) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw AuthError.network("Bad Spotify URL.")
        }
        let token = try await validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network("No response from Spotify.")
        }
        if http.statusCode == 401 {
            disconnect()
            throw AuthError.reconnectRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.network("Spotify request failed (HTTP \(http.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Presentation anchor

/// Supplies the window `ASWebAuthenticationSession` anchors its sheet to. Held
/// by the controller because the session keeps only a weak reference. The
/// anchor is captured up front on the main actor (see `runAuthSession`) so this
/// callback never touches `NSApp` off the main thread.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: NSWindow?) {
        self.anchor = anchor ?? ASPresentationAnchor()
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

// MARK: - Wire types

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}

private struct APIMe: Decodable {
    let display_name: String?
    let id: String?
}

private struct APIPlaylistPage: Decodable {
    let items: [Item]?
    let next: String?
    struct Item: Decodable {
        let id: String?
        let name: String?
        let owner: Owner?
        let images: [Image]?
        let tracks: Count?
        let items: Count?
        let external_urls: ExternalURLs?
        struct Owner: Decodable { let display_name: String? }
        struct Image: Decodable { let url: String? }
        struct Count: Decodable { let total: Int? }
        struct ExternalURLs: Decodable { let spotify: String? }
    }
}

private extension CharacterSet {
    /// `application/x-www-form-urlencoded` value encoding (stricter than
    /// `.urlQueryAllowed` — escapes `+`, `&`, `=`, etc.).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
