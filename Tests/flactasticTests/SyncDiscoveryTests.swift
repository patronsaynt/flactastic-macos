import Foundation
import Network
import Testing
@testable import flactastic

// Tests for the discovery layer. TXTRecordCodec gets the thorough treatment
// because it parses bytes written by strangers on the network; the advertiser
// gets a single live check that Bonjour registration actually succeeds, since
// a misconfigured Info.plist fails silently and looks identical to "nobody
// else is running FLACtastic".

// MARK: - TXT round-trip

@Test("A TXT record round-trips")
func txtRoundTrips() throws {
    let id = UUID()
    let entries = TXTRecordCodec.encode(
        deviceID: id, displayName: "Studio Mac", kind: .mac, isPairingOpen: true
    )
    let peer = try #require(TXTRecordCodec.decode(entries, endpointDescription: "test"))
    #expect(peer.deviceID == id)
    #expect(peer.displayName == "Studio Mac")
    #expect(peer.kind == .mac)
    #expect(peer.isPairingOpen)
    #expect(peer.isCompatible)
}

@Test("The record contains only the documented keys")
func txtLeaksNothing() {
    // A TXT record is broadcast unencrypted to everyone on the network. This
    // test exists so that adding a field is a deliberate act with a failing
    // test attached, not something that slips in.
    let entries = TXTRecordCodec.encode(
        deviceID: UUID(), displayName: "Mac", kind: .mac, isPairingOpen: false
    )
    #expect(Set(entries.keys) == ["v", "id", "n", "k", "p"])
}

@Test("Long display names are clamped to a DNS-safe length")
func txtClampsLongNames() {
    let entries = TXTRecordCodec.encode(
        deviceID: UUID(), displayName: String(repeating: "é", count: 200),
        kind: .mac, isPairingOpen: false
    )
    let name = try! #require(entries["n"])
    #expect(name.utf8.count <= TXTRecordCodec.maxValueBytes)
}

// MARK: - Hostile records

@Test("Records missing required fields are ignored, not surfaced")
func rejectsIncompleteRecords() {
    // Noise on a shared service type is ordinary, not an error to report.
    #expect(TXTRecordCodec.decode([:], endpointDescription: "e") == nil)
    #expect(TXTRecordCodec.decode(["id": "not-a-uuid", "v": "1.0"], endpointDescription: "e") == nil)
    #expect(TXTRecordCodec.decode(["id": UUID().uuidString], endpointDescription: "e") == nil)
    #expect(TXTRecordCodec.decode(["id": UUID().uuidString, "v": "banana"], endpointDescription: "e") == nil)
    #expect(TXTRecordCodec.decode(["id": UUID().uuidString, "v": "1"], endpointDescription: "e") == nil)
}

@Test("An unknown device kind degrades instead of failing")
func unknownKindDegrades() throws {
    let peer = try #require(TXTRecordCodec.decode(
        ["id": UUID().uuidString, "v": "1.0", "k": "toaster", "n": "Kitchen"],
        endpointDescription: "e"
    ))
    #expect(peer.kind == .other)
    #expect(peer.displayName == "Kitchen")
}

@Test("An incompatible major version is surfaced rather than hidden")
func incompatibleVersionIsVisible() throws {
    // The peer is still listed — the user needs to be told to update, not left
    // wondering why their other Mac never appears.
    let peer = try #require(TXTRecordCodec.decode(
        ["id": UUID().uuidString, "v": "99.0"], endpointDescription: "e"
    ))
    #expect(!peer.isCompatible)
}

@Test("Control characters and bidi overrides are stripped from names")
func sanitisesHostileNames() {
    // A device name goes straight into the UI. Right-to-left overrides let a
    // hostile peer render as a different name than it advertises, which is the
    // whole game when the user is picking which device to trust.
    let hostile = "Studio\u{202E}kaM\u{0007}\n"
    let cleaned = TXTRecordCodec.sanitizeDisplayName(hostile, fallback: "Device")
    #expect(!cleaned.unicodeScalars.contains { (0x202A ... 0x202E).contains($0.value) })
    #expect(!cleaned.contains("\u{0007}"))
    #expect(!cleaned.contains("\n"))
}

@Test("An empty or all-control name falls back rather than rendering blank")
func emptyNameFallsBack() {
    #expect(TXTRecordCodec.sanitizeDisplayName("", fallback: "iPhone") == "iPhone")
    #expect(TXTRecordCodec.sanitizeDisplayName("   ", fallback: "iPhone") == "iPhone")
    #expect(TXTRecordCodec.sanitizeDisplayName("\u{0001}\u{0002}", fallback: "iPhone") == "iPhone")
    #expect(TXTRecordCodec.sanitizeDisplayName(nil, fallback: "iPhone") == "iPhone")
}

@Test("A very long hostile name cannot push a row off screen")
func clampsHostileName() {
    let cleaned = TXTRecordCodec.sanitizeDisplayName(String(repeating: "A", count: 5000), fallback: "Device")
    #expect(cleaned.count <= 63)
}

@Test("Version parsing accepts only major.minor")
func versionParsing() {
    #expect(TXTRecordCodec.parseVersion("1.0") == SyncProtocol.Version(major: 1, minor: 0))
    #expect(TXTRecordCodec.parseVersion("12.34") == SyncProtocol.Version(major: 12, minor: 34))
    for bad in ["1", "1.2.3", "", "-1.0", "1.-2", "x.y", "1.0 "] {
        #expect(TXTRecordCodec.parseVersion(bad) == nil, "accepted \(bad)")
    }
}

// MARK: - Live Bonjour

@Test("The advertiser reaches ready and binds a port", .timeLimit(.minutes(1)))
@MainActor
func advertiserBindsAndAdvertises() async throws {
    // This is the check that catches a missing NSBonjourServices entry or a
    // denied Local Network permission — both of which otherwise present as an
    // empty device list with no error anywhere.
    let advertiser = PeerAdvertiser()
    defer { advertiser.stop() }

    advertiser.start()

    var waited = Duration.zero
    while advertiser.boundPort == nil && advertiser.failureMessage == nil && waited < .seconds(10) {
        try await Task.sleep(for: .milliseconds(100))
        waited += .milliseconds(100)
    }

    if let failure = advertiser.failureMessage {
        // Sandboxed or network-restricted CI can legitimately refuse to bind.
        // Record it rather than failing the suite, but make it loud — this is
        // exactly the symptom a real user would report.
        Issue.record("Listener could not start: \(failure)")
        return
    }

    #expect(advertiser.isAdvertising)
    #expect(advertiser.boundPort != nil)
}

@Test("Stopping the advertiser tears the listener down", .timeLimit(.minutes(1)))
@MainActor
func advertiserStops() async throws {
    // Advertising is opt-in and must actually end when the user leaves the
    // screen — a listener that outlives the UI is the thing this design is
    // most careful to avoid.
    let advertiser = PeerAdvertiser()
    advertiser.start()
    advertiser.stop()
    #expect(!advertiser.isAdvertising)
    #expect(advertiser.boundPort == nil)
}
