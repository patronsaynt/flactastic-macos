import Foundation
import Testing
@testable import flactastic

// A self-signed ECDSA P-256 certificate made with openssl. Its expected pin
// was computed independently: `openssl x509 -pubkey | openssl pkey -pubin
// -outform der | openssl dgst -sha256`, then base32 as the server's Go code
// (`base32.StdEncoding` of SHA-256(RawSubjectPublicKeyInfo), first 12).
private let testCertificate = Data(base64Encoded: "MIIBajCCARCgAwIBAgIUQXxtmjFUHCb8W9dxeWCCi/QvUxgwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPZmxhY3Rhc3RpYy10ZXN0MCAXDTI2MTExMDE1NTQwN1oYDzIxMjYxMDE3MTU1NDA3WjAaMRgwFgYDVQQDDA9mbGFjdGFzdGljLXRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQmZHjnltz0Bzqcn2gW5jyxros5E/M5qZUq9UBqrKFFV9V+CqowlknQ1lITaYKfzLLg9STqtIiChFhEhvtpwboZozIwMDAdBgNVHQ4EFgQUU73nud5pb06Jw6xxXJBTwb/W/UMwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAySsmc6Inovastwh3MpzVN94h6KdFqvv9OqI0gEvyCmECIDrk+p9OQAEEjASVSqH68I1vvKMf5d5hxuMWIF34Gx+H")!

@Test("The pin is SHA-256 of the certificate's SPKI and displays like flactastic-server info")
func serverPinMatchesServer() throws {
    let digest = try #require(ServerPin.digest(ofCertificate: testCertificate))
    #expect(digest.map { String(format: "%02x", $0) }.joined()
        == "f1840b4b315579ed5b7b74dcc19376fd6cd3b1130300426558dfc1fc8aa2b956")
    #expect(ServerPin.display(digest) == "6GCA-WSZR-KV46")
}

@Test("Malformed certificates yield no pin")
func serverPinRejectsGarbage() {
    #expect(ServerPin.digest(ofCertificate: Data()) == nil)
    #expect(ServerPin.digest(ofCertificate: Data([0x30, 0x82, 0xFF, 0xFF, 0x30])) == nil)
    #expect(ServerPin.digest(ofCertificate: testCertificate.prefix(100)) == nil)
}

@Test("Base32 follows RFC 4648")
func base32Vectors() {
    #expect(ServerPin.base32(Data("foobar".utf8)) == "MZXW6YTBOI")
    #expect(ServerPin.base32(Data("f".utf8)) == "MY")
}

@Test("Typed addresses parse with the default port")
func typedAddresses() {
    #expect(ServerAddress(typed: "nas.local") == ServerAddress(host: "nas.local", port: 4410))
    #expect(ServerAddress(typed: " 192.168.1.20:8443 ") == ServerAddress(host: "192.168.1.20", port: 8443))
    #expect(ServerAddress(typed: "https://nas.local:4410/v2") == ServerAddress(host: "nas.local", port: 4410))
    #expect(ServerAddress(typed: "[fe80::1%en0]:4410") == ServerAddress(host: "fe80::1%en0", port: 4410))
    #expect(ServerAddress(typed: "fd00::5") == ServerAddress(host: "fd00::5", port: 4410))
    #expect(ServerAddress(typed: "nas:0") == nil)
    #expect(ServerAddress(typed: "a b") == nil)
    #expect(ServerAddress(typed: "") == nil)
    #expect(ServerAddress(host: "fe80::1%en0").baseURL.absoluteString == "https://[fe80::1%25en0]:4410")
}

@Test("Error codes map to their own text, and Retry-After is read")
func serverErrorMapping() throws {
    let http = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 429, httpVersion: nil,
                               headerFields: ["Retry-After": "120"])!
    let body = Data(#"{"error":{"code":"rateLimited","message":"slow down"}}"#.utf8)
    #expect(throws: ServerError.api(code: "rateLimited", status: 429, retryAfter: 120)) {
        try ServerClient.check(http, body: body)
    }
    #expect(ServerError.api(code: "rateLimited", status: 429, retryAfter: 120).errorDescription
        == "Too many tries. Try again in 2 min.")
    let garbled = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
    #expect(throws: ServerError.api(code: "internalFailure", status: 500, retryAfter: nil)) {
        try ServerClient.check(garbled, body: Data("<html>".utf8))
    }
}

@Test("Tokens round-trip through the Keychain and are deleted")
func tokenStorage() throws {
    let profile = UUID()
    defer { try? ServerTokenStore.delete(profile) }
    #expect(try ServerTokenStore.token(for: profile) == nil)
    try ServerTokenStore.store("abc_DEF-123", for: profile)
    #expect(try ServerTokenStore.token(for: profile) == "abc_DEF-123")
    try ServerTokenStore.store("replaced", for: profile)
    #expect(try ServerTokenStore.token(for: profile) == "replaced")
    try ServerTokenStore.delete(profile)
    #expect(try ServerTokenStore.token(for: profile) == nil)
}

@Test("A cancelled request (the background long-poll stopping) is not 'can't reach'")
func cancellationIsNotUnreachable() {
    let client = ServerClient(address: ServerAddress(host: "x.invalid"), pin: nil)
    #expect(client.mapTransport(URLError(.cancelled)) is CancellationError)
    #expect(client.mapTransport(CancellationError()) is CancellationError)
    #expect(client.mapTransport(URLError(.cannotConnectToHost)) as? ServerError == .unreachable(URLError(.cannotConnectToHost).localizedDescription))
}

@Test("An import on a server library is tagged on this Mac before it uploads; the server never sees the write")
func importIsTaggedLocally() async throws {
    let dir = try FixtureSupport.makeTempDir("import-tags")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Mirrors.wav")
    try FixtureSupport.writeSilentWAV(to: file)
    // An unreachable server: any request would fail the write.
    let client = ServerClient(address: ServerAddress(host: "127.0.0.1", port: 9), pin: Data(repeating: 0, count: 32))
    let writer = MetadataWriter()
    await writer.setServer(ServerTagEditor(client: client, root: dir, streamer: ServerStreamer()))

    let track = Track(url: file, title: "Mirrors", fileFormat: .wav)
    let written = try await writer.write(to: track, title: "Mirrors", artist: "Angel Zero", album: "Mirrors - Single",
                                         year: nil, genre: nil, trackNumber: nil)
    #expect(written.artist == "Angel Zero")
    let reread = await LibraryScanner().loadMetadata(for: track)
    #expect(reread.artist == "Angel Zero")
    #expect(reread.album == "Mirrors - Single")
}
