import Foundation
import Testing
@testable import flactastic

/// Answers `PATCH /v2/tracks/{id}` as a server would, or not at all.
final class FakeEditServer: URLProtocol, @unchecked Sendable {
    enum Mode { case online, offline, reject }
    nonisolated(unsafe) static var mode = Mode.online
    nonisolated(unsafe) static var patches: [(id: String, body: [String: Any])] = []
    static let lock = NSLock()

    static func reset(_ m: Mode) { lock.withLock { mode = m; patches = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let mode = Self.lock.withLock { Self.mode }
        if mode == .offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let id = request.url!.lastPathComponent
        if mode == .reject {
            return reply(422, #"{"error":{"code":"invalidValue","message":""}}"#)
        }
        let body = (request.httpBody ?? Self.read(request.httpBodyStream))
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.lock.withLock { Self.patches.append((id, fields)) }
        let title = fields["title"] as? String ?? "Old"
        reply(200, #"{"track":{"id":"\#(id)","relativePath":"A/01 x.flac","format":"flac","fileSize":1,"tagFingerprint":"f","title":"\#(title)"}}"#)
    }

    private func reply(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}

@Suite(.serialized)
struct ServerStagedEditsTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString)")
    var file: URL { dir.appendingPathComponent("staged-edits.json") }
    let track = Track(url: URL(fileURLWithPath: "/m/A/01 x.flac"), title: "Old", fileFormat: .flac)

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func editor(rejected: (@Sendable (UUID) -> Void)? = nil) -> ServerTagEditor {
        let client = ServerClient(address: ServerAddress(host: "edits.test"), pin: nil, token: "t",
                                  protocolClasses: [FakeEditServer.self])
        return ServerTagEditor(client: client, root: URL(fileURLWithPath: "/m"), stagingFile: file, onRejected: rejected)
    }

    func edit(_ pairs: [String: JSONValue]) -> TagEdit {
        var e = TagEdit()
        e.fields = pairs
        return e
    }

    @Test("Offline, edits to a track merge, stay queued, and outlive the app")
    func offlineQueues() async throws {
        FakeEditServer.reset(.offline)
        let e = editor()
        e.stage(edit(["title": .string("First"), "label": .string("pgLang")]), for: track)
        e.stage(edit(["title": .string("Second")]), for: track)
        #expect(try await e.sendStaged(track) == nil)
        #expect(e.stagedCount == 1)

        let reopened = editor()
        #expect(reopened.stagedCount == 1)
        FakeEditServer.reset(.online)
        await reopened.flushStaged()
        #expect(reopened.stagedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let sent = try #require(FakeEditServer.patches.first)
        #expect(sent.id == track.id.uuidString)
        #expect(sent.body["title"] as? String == "Second")
        #expect(sent.body["label"] as? String == "pgLang")
    }

    @Test("Online, a staged edit is sent at once and the server's track comes back")
    func onlineSends() async throws {
        FakeEditServer.reset(.online)
        let e = editor()
        e.stage(edit(["title": .string("New")]), for: track)
        let back = try #require(try await e.sendStaged(track))
        #expect(back.title == "New")
        #expect(e.stagedCount == 0)
    }

    @Test("An edit the server refuses leaves the queue and asks for the server's file")
    func rejectedDrops() async throws {
        FakeEditServer.reset(.reject)
        let refused = LockedBox<UUID?>(nil)
        let e = editor { id in refused.set(id) }
        e.stage(edit(["title": .string("Bad")]), for: track)
        await #expect(throws: ServerError.self) { _ = try await e.sendStaged(track) }
        #expect(e.stagedCount == 0)
        #expect(refused.get() == track.id)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}
