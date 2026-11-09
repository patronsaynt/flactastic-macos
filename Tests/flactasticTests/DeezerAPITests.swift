import Foundation
import Testing
@testable import flactastic

// Deezer rate limiting and error replies, against canned responses served by
// a URLProtocol stub. Nothing here reaches Deezer.

/// Serves queued replies, one per request, and counts requests.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requestCount = 0
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let reply = Self.replies.isEmpty ? (status: 200, body: "{}") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(_ replies: [(Int, String)]) -> URLSession {
        lock.lock()
        self.replies = replies.map { (status: $0.0, body: $0.1) }
        requestCount = 0
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

private let quota = #"{"error":{"type":"Exception","message":"Quota limit exceeded","code":4}}"#
private let url = URL(string: "https://api.deezer.com/search/artist?q=Zedd")!

// The stub's counters are shared, so these run one at a time.
@Suite(.serialized) struct DeezerAPITests {

    @Test func errorBodyIsRecognised() {
        let failure = DeezerAPI.failure(in: Data(quota.utf8))
        #expect(failure?.code == 4)
        #expect(failure?.isRateLimit == true)
        #expect(DeezerAPI.failure(in: Data(#"{"data":[]}"#.utf8)) == nil)
    }

    @Test func quotaErrorBacksOffAndRetriesOnce() async throws {
        let session = StubProtocol.session([(200, quota), (200, #"{"data":[]}"#)])
        let limiter = DeezerRateLimiter(window: 0.2)

        let started = Date()
        let data = try await DeezerAPI.get(URLRequest(url: url), session: session, priority: .background, limiter: limiter)

        #expect(String(decoding: data, as: UTF8.self) == #"{"data":[]}"#)
        #expect(StubProtocol.requestCount == 2)
        #expect(Date().timeIntervalSince(started) >= 0.2)
    }

    @Test func secondQuotaErrorIsThrownNotMisreadAsData() async throws {
        let session = StubProtocol.session([(200, quota), (200, quota)])
        let limiter = DeezerRateLimiter(window: 0.05)

        await #expect(throws: DeezerAPI.Failure.self) {
            try await DeezerAPI.get(URLRequest(url: url), session: session, priority: .background, limiter: limiter)
        }
        #expect(StubProtocol.requestCount == 2)
    }

    @Test func otherDeezerErrorsAreNotRetried() async throws {
        let session = StubProtocol.session([(200, #"{"error":{"type":"DataException","message":"no data","code":800}}"#)])

        await #expect(throws: DeezerAPI.Failure(code: 800, message: "no data")) {
            try await DeezerAPI.get(URLRequest(url: url), session: session, priority: .background,
                                    limiter: DeezerRateLimiter(window: 0.05))
        }
        #expect(StubProtocol.requestCount == 1)
    }

    @Test func backgroundWorkLeavesRoomForInteractiveRequests() async {
        let limiter = DeezerRateLimiter(window: 60, backgroundLimit: 3, interactiveLimit: 5)
        for _ in 0..<3 { await limiter.acquire(.background) }

        // Background is now full for a minute, but a search still goes through.
        let blocked = Task { await limiter.acquire(.background); return true }
        await limiter.acquire(.interactive)
        await limiter.acquire(.interactive)
        #expect(await limiter.recentCount == 5)
        blocked.cancel()
    }
}
