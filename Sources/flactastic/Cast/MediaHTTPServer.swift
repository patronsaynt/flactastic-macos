import Foundation
import Network
import os

// MARK: - Request parsing

struct HTTPRequestHead: Equatable, Sendable {
    let method: String
    let path: String
    let version: String
    /// Lower-cased header names.
    let headers: [String: String]

    var wantsKeepAlive: Bool {
        let connection = headers["connection"]?.lowercased()
        if version == "HTTP/1.0" { return connection == "keep-alive" }
        return connection != "close"
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    /// Parses one request head from the front of `buffer`. Returns the head and
    /// the number of bytes it occupied, or nil if the head is incomplete.
    /// Throws for malformed input.
    static func parse(_ buffer: Data) throws -> (HTTPRequestHead, Int)? {
        guard let end = buffer.range(of: terminator) else { return nil }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw HTTPParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rawTarget = String(requestLine[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget
        let head = HTTPRequestHead(method: String(requestLine[0]).uppercased(), path: path,
                                   version: String(requestLine[2]).uppercased(), headers: headers)
        return (head, end.upperBound - buffer.startIndex)
    }
}

enum HTTPParseError: Error { case malformed }

/// A single `Range: bytes=…` request resolved against a body size.
enum ByteRangeRequest: Equatable {
    case full
    case partial(ClosedRange<Int64>)
    case unsatisfiable

    static func resolve(_ header: String?, size: Int64) -> ByteRangeRequest {
        guard let header = header?.trimmingCharacters(in: .whitespaces).lowercased(),
              header.hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count)
        // Multi-range requests are rare from renderers; serving the whole
        // body is a valid response to them.
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .full }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // Suffix range: the final N bytes.
            guard let suffix = Int64(last), suffix > 0 else { return .unsatisfiable }
            guard size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        }
        guard let start = Int64(first), start >= 0 else { return .full }
        guard start < size else { return .unsatisfiable }
        let end = last.isEmpty ? size - 1 : min(Int64(last) ?? (size - 1), size - 1)
        guard end >= start else { return .unsatisfiable }
        return .partial(start...end)
    }
}

// MARK: - Server

/// What a token serves.
struct MediaResource: Sendable {
    enum Body: Sendable {
        case file(URL)
        case data(Data)
    }
    let body: Body
    let mimeType: String
    /// DLNA streaming headers apply to audio; artwork is "interactive".
    let isAudio: Bool
}

/// A tiny HTTP/1.1 server that hands renderers the files they were told to
/// play. Only tokens registered by the active session resolve — the URL space
/// never maps onto the filesystem — and every response supports byte ranges
/// so a renderer can resume or seek after a Wi-Fi hiccup without restarting.
final class MediaHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flactastic.media-http", qos: .userInitiated)
    private let resources = OSAllocatedUnfairLock(initialState: ResourceTable())
    private var listener: NWListener?
    private let portLock = OSAllocatedUnfairLock<UInt16?>(initialState: nil)

    /// Kept small: a session only ever needs the current and next tracks plus
    /// their artwork, with a little slack for renderers that re-request.
    static let capacity = 24

    var port: UInt16? { portLock.withLock { $0 } }

    private struct ResourceTable {
        var byToken: [String: MediaResource] = [:]
        var order: [String] = []
    }

    // MARK: Lifecycle

    /// Starts listening on an ephemeral port (idempotent) and returns it.
    func start() async throws -> UInt16 {
        if let port { return port }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.portLock.withLock { $0 = port }
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    self?.portLock.withLock { $0 = nil }
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    self?.portLock.withLock { $0 = nil }
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                HTTPConnection(connection: connection, server: self, queue: self.queue).start()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        portLock.withLock { $0 = nil }
        resources.withLock { $0 = ResourceTable() }
    }

    // MARK: Registry

    /// Registers a resource and returns its URL path, e.g. `/t/<token>.flac`.
    func register(_ resource: MediaResource, fileExtension: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        resources.withLock { table in
            table.byToken[token] = resource
            table.order.append(token)
            while table.order.count > Self.capacity {
                table.byToken[table.order.removeFirst()] = nil
            }
        }
        return "/\(resource.isAudio ? "t" : "a")/\(token).\(fileExtension)"
    }

    /// Resolves a request path to its resource. The token is the final path
    /// component minus extension; anything else (traversal, unknown prefix,
    /// expired token) is a miss.
    func resource(forPath path: String) -> MediaResource? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0].isEmpty,
              components[1] == "t" || components[1] == "a" else { return nil }
        let token = components[2].split(separator: ".").first.map(String.init) ?? ""
        guard token.count == 32, token.allSatisfy(\.isHexDigit) else { return nil }
        return resources.withLock { $0.byToken[token] }
    }
}

// MARK: - Connection

/// Serves sequential requests on one keep-alive connection. Confined to the
/// server's queue.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: MediaHTTPServer?
    private let queue: DispatchQueue
    private var buffer = Data()
    private var file: FileHandle?
    /// For the timing log: what's being sent and since when.
    private var transfer: (label: String, started: Date, sent: Int64, length: Int64)?

    private static let chunkSize = 256 * 1024
    private static let maxHeadSize = 32 * 1024

    init(connection: NWConnection, server: MediaHTTPServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed:
                finish()
            case .cancelled:
                closeFile()
                // Break the connection → handler → self cycle.
                connection.stateUpdateHandler = nil
            default: break
            }
        }
        connection.start(queue: queue)
        readHead()
    }

    private func readHead() {
        do {
            if let (head, consumed) = try HTTPRequestHead.parse(buffer) {
                buffer.removeFirst(consumed)
                respond(to: head)
                return
            }
        } catch {
            sendSimple(status: "400 Bad Request", keepAlive: false)
            return
        }
        guard buffer.count < Self.maxHeadSize else {
            sendSimple(status: "431 Request Header Fields Too Large", keepAlive: false)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                finish()
                return
            }
            readHead()
        }
    }

    private func respond(to head: HTTPRequestHead) {
        let keepAlive = head.wantsKeepAlive
        guard head.method == "GET" || head.method == "HEAD" else {
            sendSimple(status: "405 Method Not Allowed", keepAlive: keepAlive)
            return
        }
        guard let resource = server?.resource(forPath: head.path),
              let size = Self.size(of: resource) else {
            sendSimple(status: "404 Not Found", keepAlive: keepAlive)
            return
        }

        let label = "\(head.method) \(head.path.prefix(11))… range=\(head.headers["range"] ?? "none")"
        castLog.notice("http \(label, privacy: .public) (\(size, privacy: .public) bytes)")

        var headers: [(String, String)] = [
            ("Content-Type", resource.mimeType),
            ("Accept-Ranges", "bytes"),
            ("Server", "macOS UPnP/1.0 FLACtastic/1.0"),
            ("Connection", keepAlive ? "keep-alive" : "close"),
            ("transferMode.dlna.org", resource.isAudio ? "Streaming" : "Interactive"),
        ]
        if resource.isAudio {
            headers.append(("contentFeatures.dlna.org", DIDLLite.dlnaFeatures))
        }

        let status: String
        let range: ClosedRange<Int64>
        switch ByteRangeRequest.resolve(head.headers["range"], size: size) {
        case .full:
            status = "200 OK"
            range = 0...max(size - 1, 0)
        case .partial(let r):
            status = "206 Partial Content"
            range = r
            headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"))
        case .unsatisfiable:
            headers.append(("Content-Range", "bytes */\(size)"))
            sendSimple(status: "416 Range Not Satisfiable", keepAlive: keepAlive, extra: headers)
            return
        }
        let length = size == 0 ? 0 : range.upperBound - range.lowerBound + 1
        headers.append(("Content-Length", String(length)))

        let headData = Self.head(status: status, headers: headers)
        guard head.method == "GET", length > 0 else {
            send(headData, then: { [self] in next(keepAlive) })
            return
        }

        switch resource.body {
        case .data(let data):
            let lower = Int(range.lowerBound)
            let slice = data.subdata(in: (data.startIndex + lower)..<(data.startIndex + lower + Int(length)))
            send(headData + slice, then: { [self] in next(keepAlive) })
        case .file(let url):
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: UInt64(range.lowerBound))
                file = handle
            } catch {
                sendSimple(status: "404 Not Found", keepAlive: keepAlive)
                return
            }
            transfer = (label, Date(), 0, length)
            send(headData, then: { [self] in streamFile(remaining: length, keepAlive: keepAlive) })
        }
    }

    /// Sends the file a chunk at a time; each chunk is read only after the
    /// previous one was handed to the network, so memory stays flat and a slow
    /// renderer naturally throttles us through TCP backpressure.
    private func streamFile(remaining: Int64, keepAlive: Bool) {
        guard remaining > 0, let file else {
            logTransfer(complete: true)
            closeFile()
            next(keepAlive)
            return
        }
        let count = Int(min(Int64(Self.chunkSize), remaining))
        let chunk: Data
        do {
            chunk = try file.read(upToCount: count) ?? Data()
        } catch {
            finish()
            return
        }
        guard !chunk.isEmpty else {
            // File shrank underneath us — the declared length can't be met.
            finish()
            return
        }
        send(chunk, then: { [self] in
            transfer?.sent += Int64(chunk.count)
            streamFile(remaining: remaining - Int64(chunk.count), keepAlive: keepAlive)
        })
    }

    private func next(_ keepAlive: Bool) {
        if keepAlive { readHead() } else { finish() }
    }

    private func send(_ data: Data, then: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [self] error in
            if error != nil {
                finish()
                return
            }
            then()
        })
    }

    private func sendSimple(status: String, keepAlive: Bool, extra: [(String, String)] = []) {
        var headers = extra.filter { $0.0 != "Content-Length" && $0.0 != "Connection" }
        headers.append(("Content-Length", "0"))
        headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        send(Self.head(status: status, headers: headers), then: { [self] in next(keepAlive) })
    }

    private func finish() {
        closeFile()
        connection.cancel()
    }

    private func closeFile() {
        if file != nil { logTransfer(complete: false) }
        try? file?.close()
        file = nil
    }

    /// Renderers routinely drop a connection mid-file (they buffer a chunk,
    /// then reconnect with a Range), so an early close isn't an error.
    private func logTransfer(complete: Bool) {
        guard let t = transfer else { return }
        transfer = nil
        let seconds = Date().timeIntervalSince(t.started)
        let rate = seconds > 0 ? Double(t.sent) / seconds / 1_048_576 : 0
        castLog.notice("http \(complete ? "finished" : "closed by renderer", privacy: .public) \(t.label, privacy: .public): \(t.sent, privacy: .public)/\(t.length, privacy: .public) bytes in \(seconds, format: .fixed(precision: 2), privacy: .public)s (\(rate, format: .fixed(precision: 1), privacy: .public) MB/s)")
    }

    private static func head(status: String, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static func size(of resource: MediaResource) -> Int64? {
        switch resource.body {
        case .data(let data):
            return Int64(data.count)
        case .file(let url):
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value
        }
    }
}
