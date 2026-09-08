import Foundation
import Testing
@testable import flactastic

// Tests for FrameCodec and WireMessage — the parts of the sync protocol that
// read bytes a peer chose. A stream delivers no message boundaries, so the
// decoder has to survive headers split across reads, payloads split across
// many, and length prefixes that were never meant to be honoured.

// MARK: - Round-trips

@Test("A control frame round-trips")
func controlFrameRoundTrips() throws {
    let payload = Data("hello".utf8)
    let encoded = try FrameCodec.encode(.init(type: .control, payload: payload))
    #expect(encoded.count == FrameCodec.headerBytes + payload.count)

    var decoder = FrameCodec.Decoder()
    decoder.append(encoded)
    let frame = try #require(try decoder.next())
    #expect(frame.type == .control)
    #expect(frame.payload == payload)
    #expect(try decoder.next() == nil)
}

@Test("An empty payload round-trips")
func emptyPayloadRoundTrips() throws {
    let encoded = try FrameCodec.encode(.init(type: .fileChunk, payload: Data()))
    var decoder = FrameCodec.Decoder()
    decoder.append(encoded)
    let frame = try #require(try decoder.next())
    #expect(frame.payload.isEmpty)
}

@Test("Back-to-back frames in one read are all recovered")
func drainsMultipleFrames() throws {
    var stream = Data()
    for index in 0 ..< 5 {
        stream += try FrameCodec.encode(.init(type: .fileChunk, payload: Data([UInt8(index)])))
    }
    var decoder = FrameCodec.Decoder()
    decoder.append(stream)
    let frames = try decoder.drain()
    #expect(frames.count == 5)
    #expect(frames.map { $0.payload.first } == [0, 1, 2, 3, 4])
}

// MARK: - Fragmentation

@Test("A frame delivered one byte at a time still decodes")
func survivesByteAtATimeDelivery() throws {
    let payload = Data(repeating: 0xAB, count: 300)
    let encoded = try FrameCodec.encode(.init(type: .fileChunk, payload: payload))

    var decoder = FrameCodec.Decoder()
    var recovered: FrameCodec.Frame?
    for byte in encoded {
        #expect(recovered == nil)          // nothing completes early
        decoder.append(Data([byte]))
        recovered = try decoder.next()
    }
    let frame = try #require(recovered)
    #expect(frame.payload == payload)
    #expect(decoder.pendingByteCount == 0)
}

@Test("A header split across two reads is not misparsed")
func survivesSplitHeader() throws {
    let payload = Data("split".utf8)
    let encoded = try FrameCodec.encode(.init(type: .control, payload: payload))

    var decoder = FrameCodec.Decoder()
    decoder.append(encoded.prefix(3))              // mid-header
    #expect(try decoder.next() == nil)
    decoder.append(encoded.dropFirst(3))
    let frame = try #require(try decoder.next())
    #expect(frame.payload == payload)
}

@Test("A truncated payload yields nothing rather than a short frame")
func truncatedPayloadYieldsNothing() throws {
    let encoded = try FrameCodec.encode(.init(type: .control, payload: Data(repeating: 1, count: 100)))
    var decoder = FrameCodec.Decoder()
    decoder.append(encoded.dropLast(10))
    #expect(try decoder.next() == nil)
    #expect(decoder.pendingByteCount > 0)          // still buffered, still waiting
}

// MARK: - Hostile input

@Test("An unknown frame type is rejected")
func rejectsUnknownFrameType() {
    var decoder = FrameCodec.Decoder()
    decoder.append(Data([99, 0, 0, 0, 0]))
    #expect(throws: FrameCodec.DecodeError.self) { try decoder.next() }
}

@Test("An oversized length prefix is rejected without buffering the payload")
func rejectsOversizedLength() {
    // The attack this blocks: a 4 GB length prefix that makes the receiver
    // wait on — and allocate for — bytes that will never arrive. The header
    // alone is enough to refuse, so no payload is ever accumulated.
    var header = Data([FrameCodec.FrameType.control.rawValue])
    var length = UInt32(SyncProtocol.maxControlFrameBytes + 1).bigEndian
    withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }

    var decoder = FrameCodec.Decoder()
    decoder.append(header)
    #expect(throws: FrameCodec.DecodeError.self) { try decoder.next() }
}

@Test("A file chunk larger than the agreed chunk size is rejected")
func rejectsOversizedChunk() {
    var header = Data([FrameCodec.FrameType.fileChunk.rawValue])
    var length = UInt32(SyncProtocol.fileChunkBytes + 1).bigEndian
    withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }

    var decoder = FrameCodec.Decoder()
    decoder.append(header)
    #expect(throws: FrameCodec.DecodeError.self) { try decoder.next() }
}

@Test("Encoding refuses an over-limit payload")
func encodeRefusesOversizedPayload() {
    let tooBig = Data(count: SyncProtocol.fileChunkBytes + 1)
    #expect(throws: FrameCodec.EncodeError.self) {
        try FrameCodec.encode(.init(type: .fileChunk, payload: tooBig))
    }
}

// MARK: - WireMessage

@Test("Every message case round-trips through JSON")
func wireMessagesRoundTrip() throws {
    let hello = WireMessage.Hello(
        version: SyncProtocol.version,
        deviceID: UUID(),
        displayName: "Studio Mac",
        deviceKind: .mac,
        isPaired: false
    )
    let entry = TrackManifestEntry(
        trackID: UUID(),
        relativePath: "Artist/Album/01 Song.flac",
        fileSize: 1234,
        contentHash: String(repeating: "a", count: 64),
        format: .flac,
        tagFingerprint: String(repeating: "b", count: 64),
        title: "Song",
        artist: "Artist",
        album: "Album"
    )
    let messages: [WireMessage] = [
        .hello(hello),
        .helloAck(hello),
        .pairCommit(.init(commitment: Data([1, 2, 3]))),
        .pairGuestKey(.init(publicKey: Data([4, 5]))),
        .pairReveal(.init(publicKey: Data([6]), nonce: Data([7]))),
        .pairConfirm(.init(mac: Data([8]), deviceID: UUID(), displayName: "Phone", deviceKind: .iPhone)),
        .pairResult(.init(success: false, failureReason: "Incorrect code")),
        .syncRequest(.init(
            direction: .push,
            filter: .unrestricted,
            manifest: LibraryManifest(deviceID: UUID(), tracks: [entry], playlists: [])
        )),
        .planProposal(.init(
            plan: SyncPlan(direction: .push, newTracks: [entry], trackConflicts: [],
                           newPlaylists: [], playlistConflicts: []),
            receiverFreeBytes: 999
        )),
        .planDecision(.init(planHash: "abc", approved: true)),
        .fileStart(.init(trackID: entry.trackID, relativePath: entry.relativePath,
                         fileSize: entry.fileSize, contentHash: entry.contentHash,
                         tagFingerprint: entry.tagFingerprint)),
        .fileAccept(.init(trackID: entry.trackID, resumeOffset: 512, skip: false)),
        .fileEnd(.init(trackID: entry.trackID)),
        .playlists(.init(playlists: [Playlist(name: "Late Night")])),
        .syncComplete(.init(tracksTransferred: 1, playlistsTransferred: 1, bytesTransferred: 1234)),
        .cancel(.init(reason: "User cancelled")),
        .protocolError(.init(code: .hashMismatch, message: "Digest did not match")),
    ]

    for message in messages {
        let first = try message.encoded()
        let decoded = try WireMessage.decoded(from: first)

        // Re-encoding is the property that actually matters, and it is the
        // strongest one available: `Date` is a floating-point interval, so no
        // textual format round-trips it bit-exactly. Dates land on the
        // millisecond grid on the first encode and stay there, which is what
        // this asserts — a message can cross any number of hops without
        // drifting.
        #expect(try decoded.encoded() == first)
    }
}

@Test("Messages without timestamps round-trip exactly")
func timestampFreeMessagesRoundTripExactly() throws {
    let messages: [WireMessage] = [
        .pairCommit(.init(commitment: Data([1, 2, 3]))),
        .pairReveal(.init(publicKey: Data([6]), nonce: Data([7]))),
        .pairResult(.init(success: false, failureReason: "Incorrect code")),
        .planDecision(.init(planHash: "abc", approved: true)),
        .fileAccept(.init(trackID: UUID(), resumeOffset: 512, skip: false)),
        .syncComplete(.init(tracksTransferred: 1, playlistsTransferred: 1, bytesTransferred: 1234)),
        .cancel(.init(reason: "User cancelled")),
        .protocolError(.init(code: .hashMismatch, message: "Digest did not match")),
    ]
    for message in messages {
        #expect(try WireMessage.decoded(from: try message.encoded()) == message)
    }
}

@Test("A date survives a round-trip to the millisecond, and is stable thereafter")
func datesAreStableAtMillisecondPrecision() throws {
    let original = Playlist(name: "Late Night")
    let once = try WireMessage.decoded(from: try WireMessage.playlists(.init(playlists: [original])).encoded())
    guard case .playlists(let firstPass) = once else { Issue.record("wrong case"); return }

    let recovered = try #require(firstPass.playlists.first)
    #expect(abs(recovered.dateCreated.timeIntervalSince(original.dateCreated)) < 0.001)

    // Second hop must not move it again — otherwise repeated syncs would walk
    // the timestamp backwards a fraction of a millisecond at a time.
    let twice = try WireMessage.decoded(from: try once.encoded())
    guard case .playlists(let secondPass) = twice else { Issue.record("wrong case"); return }
    #expect(secondPass.playlists.first?.dateCreated == recovered.dateCreated)
}

@Test("The discriminator is the documented shape")
func discriminatorShapeIsStable() throws {
    // The spec document promises `{"t": <tag>, "d": {…}}`. If this assertion
    // ever needs updating, docs/sync-protocol-v1.md needs updating too and the
    // protocol version needs a bump.
    let message = WireMessage.planDecision(.init(planHash: "abc", approved: true))
    let json = try JSONSerialization.jsonObject(with: try message.encoded()) as? [String: Any]
    #expect(json?["t"] as? String == "planDecision")
    #expect((json?["d"] as? [String: Any])?["approved"] as? Bool == true)
}

@Test("An unknown discriminator fails to decode rather than being ignored")
func rejectsUnknownDiscriminator() {
    let json = Data(#"{"t":"someFutureMessage","d":{}}"#.utf8)
    #expect(throws: (any Error).self) { try WireMessage.decoded(from: json) }
}

@Test("A control frame carrying a message round-trips end to end")
func controlMessageThroughFrame() throws {
    let message = WireMessage.cancel(.init(reason: "stop"))
    var decoder = FrameCodec.Decoder()
    decoder.append(try FrameCodec.encodeControl(message))
    let frame = try #require(try decoder.next())
    #expect(frame.type == .control)
    #expect(try WireMessage.decoded(from: frame.payload) == message)
}

// MARK: - Version compatibility

@Test("Major version must match; minor is additive")
func versionCompatibility() {
    let v1_0 = SyncProtocol.Version(major: 1, minor: 0)
    let v1_7 = SyncProtocol.Version(major: 1, minor: 7)
    let v2_0 = SyncProtocol.Version(major: 2, minor: 0)
    #expect(v1_0.isCompatible(with: v1_7))
    #expect(v1_7.isCompatible(with: v1_0))
    #expect(!v1_0.isCompatible(with: v2_0))
}
