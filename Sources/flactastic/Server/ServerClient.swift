import CryptoKit
import Foundation
import os

/// The pin on a FLACtastic Server's key (protocol v2 §3): SHA-256 of the
/// certificate's DER SubjectPublicKeyInfo, and the 12-character fingerprint a
/// person compares with what `flactastic-server info` prints.
enum ServerPin {
    static func digest(ofCertificate der: Data) -> Data? {
        subjectPublicKeyInfo(in: der).map { Data(SHA256.hash(data: $0)) }
    }

    /// `K7F2-9QX4-M3PA`: the first 12 base32 characters of the digest.
    static func display(_ digest: Data) -> String {
        let f = Array(base32(digest).prefix(12))
        return "\(String(f[0..<4]))-\(String(f[4..<8]))-\(String(f[8..<12]))"
    }

    /// RFC 4648 alphabet, uppercase, no padding.
    static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = buffer << 8 | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// The exact SPKI bytes inside an X.509 certificate: the seventh element
    /// of TBSCertificate (after the optional [0] version, serial, signature,
    /// issuer, validity and subject). Works for any key type.
    static func subjectPublicKeyInfo(in der: Data) -> Data? {
        let b = [UInt8](der)
        guard let cert = element(b, at: 0), cert.tag == 0x30,
              let tbs = element(b, at: cert.content.lowerBound), tbs.tag == 0x30 else { return nil }
        var i = tbs.content.lowerBound, index = 0
        while i < tbs.content.upperBound, let e = element(b, at: i) {
            if index == 0, e.tag == 0xA0 { i = e.end; continue }
            if index == 5 { return e.tag == 0x30 ? Data(b[i..<e.end]) : nil }
            index += 1; i = e.end
        }
        return nil
    }

    private static func element(_ b: [UInt8], at i: Int) -> (tag: UInt8, content: Range<Int>, end: Int)? {
        guard i + 2 <= b.count else { return nil }
        var length = Int(b[i + 1]), p = i + 2
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard (1...4).contains(n), p + n <= b.count else { return nil }
            length = 0
            for _ in 0..<n { length = length << 8 | Int(b[p]); p += 1 }
        }
        guard p + length <= b.count else { return nil }
        return (b[i], p..<(p + length), p + length)
    }
}

/// Checks every TLS handshake against the stored pin. With no pin (the first
/// connection) it accepts any certificate and records what it saw, so the
/// fingerprint can be shown before anything secret is sent.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let pin: Data?
    private let seen = OSAllocatedUnfairLock<Data?>(initialState: nil)

    init(pin: Data?) { self.pin = pin }

    var seenPin: Data? { seen.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let digest = ServerPin.digest(ofCertificate: SecCertificateCopyData(leaf) as Data) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        seen.withLock { $0 = digest }
        if let pin, pin != digest { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Where a server lives. Trust never depends on it: the same pin works over a
/// LAN address, a VPN or a forwarded port.
struct ServerAddress: Codable, Hashable, Sendable {
    static let defaultPort = 4410
    var host: String
    var port: Int

    init(host: String, port: Int = Self.defaultPort) {
        self.host = host
        self.port = port
    }

    /// Accepts `host`, `host:port`, `[v6]:port` and a pasted `https://` URL.
    init?(typed raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        var host = text, port = Self.defaultPort
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { guard let p = Int(rest.dropFirst()) else { return nil }; port = p }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            guard let p = Int(text[text.index(after: colon)...]) else { return nil }
            port = p
        }
        guard !host.isEmpty, (1...65535).contains(port),
              host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:%_".contains($0) }) else { return nil }
        self.init(host: host, port: port)
    }

    var baseURL: URL {
        var c = URLComponents()
        c.scheme = "https"
        // Bracket IPv6 literals; a zone ID's `%` must itself be escaped.
        c.percentEncodedHost = host.contains(":")
            ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        c.port = port
        return c.url!
    }

    var label: String { port == Self.defaultPort ? host : "\(host):\(port)" }
}

/// A server's `{ "error": { "code" } }`, or a failure reaching it. The UI
/// keys its text on `code`, never on the server's message (§5).
enum ServerError: Error, Equatable, LocalizedError {
    case api(code: String, status: Int, retryAfter: Int?)
    case identityChanged
    case unreachable(String)
    case badResponse

    var code: String? {
        if case .api(let code, _, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .identityChanged: return "This server's identity changed."
        case .unreachable: return "Can't reach the server."
        case .badResponse: return "The server sent something unexpected."
        case .api(let code, _, let retryAfter):
            switch code {
            case "invalidCredentials": return "That username and password didn't work."
            case "rateLimited": return "Too many tries. Try again in \(Self.wait(retryAfter ?? 1))."
            case "unauthorized": return "This Mac was signed out of the server."
            case "forbidden": return "That needs an admin account."
            case "notFound": return "It's no longer on the server."
            case "libraryOffline": return "The server's music folder is offline."
            case "transcodeUnavailable": return "The server is busy."
            case "insufficientStorage": return "There isn't enough space on the server."
            case "sizeExceeded": return "That's too large for the server."
            case "unsupportedFormat": return "The server doesn't take that file type."
            case "hashMismatch": return "The file arrived damaged. Try again."
            case "planStale": return "The library changed since the preview."
            case "offsetMismatch": return "The upload got out of step."
            default: return "Something went wrong on the server."
            }
        }
    }

    private static func wait(_ seconds: Int) -> String {
        seconds < 90 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded(.up))) min"
    }
}

/// HTTPS + JSON to one server, through one pinned session (§3, §4).
final class ServerClient: Sendable {
    let address: ServerAddress
    let session: URLSession
    let trust: PinningDelegate
    private let tokenLock: OSAllocatedUnfairLock<String?>
    private let lostLock = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    /// Told whenever a request or stream can't reach the server.
    var onUnreachable: (@Sendable () -> Void)? {
        get { lostLock.withLock { $0 } }
        set { lostLock.withLock { $0 = newValue } }
    }

    /// `protocolClasses` lets tests answer requests without a server.
    /// Answers every client's requests in tests, without a server.
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass] = []

    init(address: ServerAddress, pin: Data?, token: String? = nil, protocolClasses: [AnyClass] = ServerClient.testProtocolClasses) {
        self.address = address
        trust = PinningDelegate(pin: pin)
        tokenLock = OSAllocatedUnfairLock(initialState: token)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 6
        if !protocolClasses.isEmpty { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    var token: String? {
        get { tokenLock.withLock { $0 } }
        set { tokenLock.withLock { $0 = newValue } }
    }

    static let encoder = WireMessage.makeEncoder()
    static let decoder: JSONDecoder = {
        let decoder = WireMessage.makeDecoder()
        // Readers accept any number of fractional digits, or none (§4).
        let plain = ISO8601DateFormatter()
        nonisolated(unsafe) let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        nonisolated(unsafe) let whole = plain
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            guard let date = fractional.date(from: text) ?? whole.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return decoder
    }()

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                 body: Data? = nil, contentType: String = "application/json",
                 timeout: TimeInterval = 60) -> URLRequest {
        var c = URLComponents(url: address.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: timeout)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = body
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Sends a request and turns every failure into a `ServerError`.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ServerError.badResponse }
        try Self.check(http, body: data)
        return (data, http)
    }

    /// A cancelled request (the app stopping its own long-poll in the
    /// background, a skipped track) says nothing about the server, so it
    /// stays a `CancellationError` and never reads as "can't reach".
    func mapTransport(_ error: Error) -> Error {
        if let pin = trust.pin, let seen = trust.seenPin, seen != pin { return ServerError.identityChanged }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        onUnreachable?()
        return ServerError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
    }

    static func check(_ http: HTTPURLResponse, body: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        struct Envelope: Decodable { struct Inner: Decodable { let code: String }; let error: Inner }
        let code = (try? JSONDecoder().decode(Envelope.self, from: body))?.error.code ?? "internalFailure"
        let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        throw ServerError.api(code: code, status: http.statusCode, retryAfter: retry)
    }

    func json<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ path: String,
                            query: [URLQueryItem] = [], body: (any Encodable)? = nil,
                            timeout: TimeInterval = 60) async throws -> T {
        let encoded = try body.map { try Self.encoder.encode($0) }
        let (data, _) = try await self.data(for: request(method, path, query: query, body: encoded, timeout: timeout))
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw ServerError.badResponse }
    }

    /// For endpoints answering `204` (or a body the caller doesn't need).
    func send(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws {
        let encoded = try body.map { try Self.encoder.encode($0) }
        _ = try await data(for: request(method, path, body: encoded))
    }
}
