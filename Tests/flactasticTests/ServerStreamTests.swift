@preconcurrency import AVFoundation
import Foundation
import os
import Testing
@testable import flactastic

// Streaming from a FLACtastic Server without a server: transcode trimming,
// progressive originals, upload resume, mapping and edits.

private func scratch(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flactastic-server-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

/// A stereo tone whose pitch glides, so any misalignment shows in a correlation.
private func tone(frames: Int, rate: Double = 44_100) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    var phase = 0.0
    for i in 0..<frames {
        phase += 2 * .pi * (220 + 660 * Double(i) / Double(frames)) / rate
        let v = Float(sin(phase) * 0.5)
        buffer.floatChannelData![0][i] = v
        buffer.floatChannelData![1][i] = v
    }
    return buffer
}

private func write(_ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any]) throws {
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

private func readAll(_ source: any PCMSource, chunk: AVAudioFrameCount = 4096) throws -> [Float] {
    var out: [Float] = []
    let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk)!
    while source.framePosition < source.length {
        try source.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    }
    return out
}

// MARK: - Gapless transcodes

/// Apple's AAC-LC encoder primes with 2112 samples, as ffmpeg's does with
/// 1024; the decoder doesn't care which, only that the header says so.
private let applePriming = 2112

@Test("A transcoded stream trimmed by Priming and Frames is exactly the source's length, in step with it")
func adtsTrimmingIsGapless() throws {
    let frames = 66_150 // 1.5 s
    let source = tone(frames: frames)
    let url = scratch("tone.aac")
    try write(source, to: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                         AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
    let bytes = try Data(contentsOf: url)
    #expect(bytes.prefix(2) == Data([0xFF, 0xF1]) || bytes.prefix(2) == Data([0xFF, 0xF9]), "expected an ADTS stream")

    let decoder = ADTSDecoder(priming: applePriming, frames: frames)
    for start in stride(from: 0, to: bytes.count, by: 3000) {
        decoder.feed(bytes.subdata(in: start..<min(start + 3000, bytes.count)))
    }
    decoder.finish()
    let format = try decoder.waitForFormat()
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var decoded: [Float] = []
    repeat {
        try decoder.read(into: buffer, frameCount: 4096)
        decoded += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    } while buffer.frameLength > 0

    #expect(decoded.count == frames)
    #expect(decoder.delivered == Int64(frames))

    // The trimmed audio lines up with the source: the best match is at lag 0.
    let original = UnsafeBufferPointer(start: source.floatChannelData![0], count: frames)
    func correlation(_ lag: Int) -> Float {
        var sum: Float = 0
        for i in 2000..<(frames - 2000) { sum += original[i] * decoded[i + lag] }
        return sum
    }
    let best = (-40...40).max { correlation($0) < correlation($1) }
    #expect(best == 0)
}

@Test("Without FLACtastic-Frames, everything after the priming is kept")
func adtsWithoutFramesKeepsTheRest() throws {
    let url = scratch("tone.aac")
    try write(tone(frames: 44_100), to: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                      AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
    let decoder = ADTSDecoder(priming: applePriming, frames: nil)
    decoder.feed(try Data(contentsOf: url))
    decoder.finish()
    let format = try decoder.waitForFormat()
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    var total = 0
    repeat {
        try decoder.read(into: buffer, frameCount: 8192)
        total += Int(buffer.frameLength)
    } while buffer.frameLength > 0
    // The encoder pads the last packet, so a little more than the source.
    #expect(total >= 44_100 && total < 44_100 + 2048)
}

// MARK: - Originals read through Core Audio from a remote file

/// Serves one file with `Range`, slowly (4 KB every 5 ms), so reads and
/// seeks run ahead of the download. Counts requests and how many are open.
final class SlowRangeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var etag = "\"a\""
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var open = 0
    nonisolated(unsafe) static var maxOpen = 0
    static let lock = NSLock()
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        if !stopped.withLock({ let was = $0; $0 = true; return was }) { Self.lock.withLock { Self.open -= 1 } }
    }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        let ifRange = request.value(forHTTPHeaderField: "If-Range")
        let (body, etag) = Self.lock.withLock { (Self.body, Self.etag) }
        Self.lock.withLock { Self.requests.append(range); Self.open += 1; Self.maxOpen = max(Self.maxOpen, Self.open) }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        var start = Int(bounds.first ?? "0") ?? 0
        var stop = bounds.count > 1 ? (Int(bounds[1]).map { $0 + 1 } ?? body.count) : body.count
        var status = 206
        if ifRange != nil && ifRange != etag { start = 0; stop = body.count; status = 200 }
        let headers = status == 206 ? ["ETag": etag, "Content-Range": "bytes \(start)-\(stop - 1)/\(body.count)"] : ["ETag": etag]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            var at = start
            while at < stop, !self.stopped.withLock({ $0 }) {
                let end = min(stop, at + 4 << 10)
                self.client?.urlProtocol(self, didLoad: body.subdata(in: at..<end))
                at = end
                Thread.sleep(forTimeInterval: 0.005)
            }
            if !self.stopped.withLock({ let was = $0; $0 = true; return was }) {
                Self.lock.withLock { Self.open -= 1 }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    static func serve(_ data: Data) {
        lock.withLock { body = data; etag = "\"a\""; requests = []; open = 0; maxOpen = 0 }
    }
}

private func slowClient() -> ServerClient {
    ServerClient(address: ServerAddress(host: "range.invalid"), pin: nil, token: "t", protocolClasses: [SlowRangeServer.self])
}

private func frames(_ source: any PCMSource, at position: AVAudioFramePosition, count: AVAudioFrameCount) throws -> [Float] {
    source.framePosition = position
    let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count)!
    try source.read(into: buffer, frameCount: count)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

@Suite(.serialized)
struct RemoteOriginalTests {
    @Test("An original read from the server matches the file, from the start and after a seek ahead of the download",
          arguments: ["flac", "wav", "m4a"])
    func remoteSourceMatchesTheFile(ext: String) async throws {
        let original = scratch("original.\(ext)")
        let settings: [String: Any] = switch ext {
        case "flac": [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
        case "m4a": [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        default: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        }
        try write(tone(frames: 44_100 * 40), to: original, settings: settings)
        let bytes = try Data(contentsOf: original)
        SlowRangeServer.serve(bytes)

        let remote = try RemoteFile(client: slowClient(), trackID: UUID(), size: Int64(bytes.count), file: scratch("cache.\(ext)"))
        let format: AudioFileFormat = ext == "m4a" ? .aac : AudioFileFormat(rawValue: ext)!
        let local = try AVAudioFile(forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = try await Task.detached { try RemoteAudioSource(remote, format: format) }.value
        #expect(source.length == local.length)

        let start = try await Task.detached { try frames(source, at: 0, count: 4096) }.value
        #expect(start == (try frames(local, at: 0, count: 4096)))

        // Thirty seconds in: well past what has arrived, so it's a new Range.
        let target = AVAudioFramePosition(44_100 * 30)
        let began = Date()
        let peak = OSAllocatedUnfairLock(initialState: 0)
        let watch = Task.detached { while !Task.isCancelled { let n = StreamTask.inFlight.withLock { $0 }; peak.withLock { $0 = max($0, n) }; try? await Task.sleep(for: .milliseconds(1)) } }
        let there = try await Task.detached { try frames(source, at: target, count: 4096) }.value
        watch.cancel()
        #expect(there == (try frames(local, at: target, count: 4096)), "the same samples as the file at 30 s")
        #expect(Date().timeIntervalSince(began) < 0.5, "a seek ahead doesn't wait for the download")
        #expect(SlowRangeServer.lock.withLock { SlowRangeServer.requests.contains { $0 != "bytes=0-" } })
        #expect(peak.withLock { $0 } <= 1, "one request in flight")

        // Back to the start: already here, no request.
        let before = SlowRangeServer.lock.withLock { SlowRangeServer.requests.count }
        _ = try await Task.detached { try frames(source, at: 0, count: 4096) }.value
        #expect(SlowRangeServer.lock.withLock { SlowRangeServer.requests.count } == before, "a rewind stays local")
        remote.drop()
    }

    @Test("A file that changed on the server (If-Range answered with 200) is read again from zero")
    func remoteFileRestartsOnChange() async throws {
        let first = Data((0..<2_000_000).map { UInt8($0 % 251) })
        SlowRangeServer.serve(first)
        let remote = try RemoteFile(client: slowClient(), trackID: UUID(), size: Int64(first.count), file: scratch("x.bin"))
        func bytes(at offset: Int64) async throws -> Data {
            try await Task.detached {
                var buffer = [UInt8](repeating: 0, count: 100)
                _ = try remote.read(into: &buffer, at: offset, count: 100)
                return Data(buffer)
            }.value
        }
        _ = try await bytes(at: 0)
        // The file changes while the first range is still coming; a seek past
        // it asks with If-Range, which is refused, and the new file comes whole.
        let second = Data((0..<2_000_000).map { UInt8(($0 + 7) % 251) })
        SlowRangeServer.lock.withLock { SlowRangeServer.body = second; SlowRangeServer.etag = "\"b\"" }
        #expect(try await bytes(at: 1_500_000) == second.subdata(in: 1_500_000..<1_500_100))
        remote.drop()
    }
}

// MARK: - Upload resume

/// A pretend server for one upload: it loses bytes once (409), drops the
/// connection once, and refuses any byte past the declared size.
final class UploadStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stored = Data()
    nonisolated(unsafe) static var size = 0
    nonisolated(unsafe) static var patches = 0
    nonisolated(unsafe) static var overran = false
    nonisolated(unsafe) static var heads = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        if method == "HEAD" {
            Self.heads += 1
            respond(204, ["Upload-Offset": "\(Self.stored.count)"])
            return
        }
        let offset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? -1
        let body = Self.body(of: request)
        Self.patches += 1
        if offset + body.count > Self.size { Self.overran = true }
        switch Self.patches {
        case 2:
            // The server only kept half of what it said it had.
            Self.stored = Self.stored.prefix(Self.stored.count / 2)
            respond(409, ["Upload-Offset": "\(Self.stored.count)"], #"{"error":{"code":"offsetMismatch","message":""}}"#)
            return
        case 4:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        default:
            break
        }
        guard offset == Self.stored.count else {
            respond(409, ["Upload-Offset": "\(Self.stored.count)"], #"{"error":{"code":"offsetMismatch","message":""}}"#)
            return
        }
        Self.stored.append(body)
        if Self.stored.count == Self.size {
            respond(200, [:], #"{"track":{"id":"9F1C2B3A-4D5E-4F60-8A7B-0C1D2E3F4A5B","relativePath":"A/B/01 - C.flac","format":"flac","fileSize":\#(Self.size),"contentHash":null,"tagFingerprint":"00","title":"C","duration":1,"sampleRate":44100,"channels":2,"bitrate":900,"frames":44100,"secondaryGenres":[],"isCompilation":false,"isMixCompilation":false,"artistIsList":false,"albumArtistIsList":false,"hasCueSheet":false,"dateAdded":"2026-01-02T03:04:05.000Z","modified":"2026-01-02T03:04:05.000Z"}}"#)
        } else {
            respond(204, ["Upload-Offset": "\(Self.stored.count)"])
        }
    }

    private func respond(_ status: Int, _ headers: [String: String], _ body: String = "") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Test("An upload resumes from the server's offset after a 409 and a dropped connection, and never sends past its size")
func uploadResumes() async throws {
    let bytes = Data((0..<1_000_000).map { UInt8($0 % 253) })
    let file = scratch("song.flac")
    try bytes.write(to: file)
    UploadStub.stored = Data()
    UploadStub.size = bytes.count
    UploadStub.patches = 0
    UploadStub.heads = 0
    UploadStub.overran = false

    let client = ServerClient(address: ServerAddress(host: "test.invalid"), pin: nil, token: "t", protocolClasses: [UploadStub.self])
    let track = try await ServerUploads.send(file, upload: UUID(), from: 0, size: Int64(bytes.count),
                                             client: client, chunk: 200_000) { _ in }
    #expect(track.relativePath == "A/B/01 - C.flac")
    #expect(UploadStub.stored == bytes)
    #expect(!UploadStub.overran)
    #expect(UploadStub.heads == 1)
}

// MARK: - Mapping and edits

@Test("A server Track maps to the app's Track under the offline folder")
func serverTrackMapping() throws {
    let json = #"""
    { "id": "9f1c2b3a-4d5e-4f60-8a7b-0c1d2e3f4a5b", "relativePath": "Daft Punk/Discovery/01 - One More Time.flac",
      "format": "flac", "fileSize": 31234567, "contentHash": null, "tagFingerprint": "ab",
      "title": "One More Time", "artist": "Daft Punk ; Romanthony", "artistIsList": true,
      "albumArtist": "Daft Punk", "albumArtistIsList": false, "album": "Discovery",
      "trackNumber": 1, "discNumber": 1, "discTotal": 1, "year": 2001,
      "genre": "Electronic", "secondaryGenres": ["House"], "isCompilation": false, "isMixCompilation": false,
      "label": "Virgin", "duration": 320.4, "sampleRate": 96000, "bitDepth": 24, "channels": 2, "bitrate": 1003,
      "frames": 30758400, "artworkID": "0123456789abcdef0123456789abcdef", "hasCueSheet": false,
      "dateAdded": "2026-01-02T03:04:05.687Z", "modified": "2026-01-02T03:04:05Z", "futureKey": 1 }
    """#
    let server = try ServerClient.decoder.decode(ServerTrack.self, from: Data(json.utf8))
    let root = URL(fileURLWithPath: "/Users/x/Music/FLACtastic/nas", isDirectory: true)
    let t = try #require(server.appTrack(root: root))
    #expect(t.id == UUID(uuidString: "9F1C2B3A-4D5E-4F60-8A7B-0C1D2E3F4A5B"))
    #expect(t.url.path == "/Users/x/Music/FLACtastic/nas/Daft Punk/Discovery/01 - One More Time.flac")
    #expect(t.fileFormat == .flac)
    #expect(t.sampleRate == 96_000)
    #expect(t.bitDepth == 24)
    #expect(t.artist == "Daft Punk ; Romanthony")
    #expect(t.artistIsList)
    #expect(t.secondaryGenres == ["House"])
    #expect(t.artworkID == "0123456789abcdef0123456789abcdef")
    #expect(t.discTotal == 1)
    #expect(server.manifestEntry == nil, "unhashed tracks stay out of manifests")

    var hostile = server
    hostile.relativePath = "../../.zshrc.flac"
    #expect(hostile.appTrack(root: root) == nil)
    hostile.relativePath = "a.flac"
    hostile.format = "ogg"
    #expect(hostile.appTrack(root: root) == nil)
}

@Test("An edit sends only what changed: absent, null to clear, or the value")
func tagEditIsThreeState() throws {
    let t = Track(url: URL(fileURLWithPath: "/x.flac"), title: "One", artist: "A", album: "Alb", trackNumber: 3,
                  fileFormat: .flac, genre: "House", year: 2001, label: "Virgin")
    let edit = TagEdit.from(t, title: "One", artist: "A ; B", album: "Alb", year: nil, genre: "House",
                            secondaryGenres: [], trackNumber: 4, artwork: .unchanged, albumArtist: .unchanged,
                            compilation: .set(true), mix: .unchanged, label: .set(nil), disc: .unchanged)
    let json = try JSONSerialization.jsonObject(with: ServerClient.encoder.encode(edit)) as! [String: Any]
    #expect(Set(json.keys) == ["artist", "year", "trackNumber", "isCompilation", "label"])
    #expect(json["artist"] as? String == "A ; B")
    #expect(json["year"] is NSNull)
    #expect(json["label"] is NSNull)
    #expect(json["isCompilation"] as? Bool == true)
    let raw = String(decoding: try ServerClient.encoder.encode(edit), as: UTF8.self)
    #expect(raw.contains(#""trackNumber":4"#), "integers go out as integers")
}

@Test("Offline copies: identical copies are kept, changed and new tracks are fetched, a re-tagged ID is adopted")
func offlineCopyDiff() {
    func entry(_ id: UUID, _ hash: String, _ tags: String = "t", path: String = "a.flac") -> TrackManifestEntry {
        TrackManifestEntry(trackID: id, relativePath: path, fileSize: 10, contentHash: hash, format: .flac,
                           tagFingerprint: tags, title: "", artist: nil, album: nil)
    }
    let same = UUID(), changed = UUID(), new = UUID(), adopted = UUID(), oldID = UUID(), retagged = UUID()
    let server = LibraryManifest(deviceID: UUID(), tracks: [
        entry(same, "h1"), entry(changed, "h2-new"), entry(new, "h3"), entry(adopted, "h4"), entry(retagged, "h5", "t2"),
    ], playlists: [])
    let local = LibraryManifest(deviceID: UUID(), tracks: [
        entry(same, "h1"), entry(changed, "h2-old"), entry(oldID, "h4"), entry(retagged, "h5", "t1"),
    ], playlists: [])
    let plan = SyncDiff.plan(incoming: server, local: local, direction: .pull, filter: SyncFilter(excludedFormats: [.mp3]))
    #expect(Set(plan.allIncomingTracks.map(\.trackID)) == [changed, new, retagged])
}

@Test("Synced settings survive the trip through JSON, Data included")
func prefsRoundTrip() {
    let values: [String: Any] = ["b": true, "i": 3, "d": 0.5, "s": "x", "a": ["p", "q"], "data": Data([1, 2, 3])]
    for (_, v) in values {
        let json = PrefsSync.json(v)!
        let back = PrefsSync.plist(json)!
        #expect((back as AnyObject).isEqual(v))
    }
    #expect(PrefsSync.json(true) == .bool(true))
    #expect(PrefsSync.json(3) == .int(3))
}
