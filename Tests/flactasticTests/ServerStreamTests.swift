@preconcurrency import AVFoundation
import AppKit
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
    /// Delay before each response, like a round trip over the internet.
    nonisolated(unsafe) static var latency: TimeInterval = 0
    /// Bytes sent and time spent sending them: the link's true rate.
    nonisolated(unsafe) static var sent = 0
    nonisolated(unsafe) static var sending: TimeInterval = 0
    static let lock = NSLock()
    static let link = NSLock()
    /// Requests at once share one link's rate (off: each gets its own).
    nonisolated(unsafe) static var sharedLink = false
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
        let latency = Self.lock.withLock { Self.latency }
        DispatchQueue.global().async {
            if latency > 0 { Thread.sleep(forTimeInterval: latency) }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var at = start
            while at < stop, !self.stopped.withLock({ $0 }) {
                // One link: requests at once share it, as they would.
                let shared = Self.lock.withLock { Self.sharedLink }
                if shared { Self.link.lock() }
                let began = Date()
                let end = min(stop, at + 4 << 10)
                self.client?.urlProtocol(self, didLoad: body.subdata(in: at..<end))
                Thread.sleep(forTimeInterval: 0.005)
                Self.lock.withLock { Self.sent += end - at; Self.sending += Date().timeIntervalSince(began) }
                if shared { Self.link.unlock() }
                at = end
            }
            if !self.stopped.withLock({ let was = $0; $0 = true; return was }) {
                Self.lock.withLock { Self.open -= 1 }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    static func serve(_ data: Data) {
        lock.withLock { body = data; etag = "\"a\""; requests = []; open = 0; maxOpen = 0; latency = 0; sent = 0; sending = 0; sharedLink = false }
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
        #expect(peak.withLock { $0 } <= 2, "at most one request coming behind another")

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

// MARK: - Mixed queues: offline copies beside streamed tracks

// In the same serialized suite as the other SlowRangeServer tests: they
// share its static state.
extension RemoteOriginalTests {
    /// An offline track and a streamed one, as the streamer knows them.
    private func rig(reachable: Bool, streamedSize: Int, hash: String? = nil) -> (ServerStreamer, Track, Track, ServerStreamer.TrackInfo) {
        let a = Track(url: scratch("mixA.flac"), title: "A", duration: 60, fileFormat: .flac)
        let b = Track(url: scratch("mixB.flac"), title: "B", duration: 60, fileFormat: .flac)
        let ia = ServerStreamer.TrackInfo(id: UUID(), format: .flac, fileSize: 1000, contentHash: nil,
                                          sampleRate: 44_100, bitrate: 1000, frames: nil, duration: 60)
        let ib = ServerStreamer.TrackInfo(id: UUID(), format: .flac, fileSize: Int64(streamedSize), contentHash: hash,
                                          sampleRate: 44_100, bitrate: 1000, frames: nil, duration: 60)
        let streamer = ServerStreamer()
        streamer.config.withLock {
            $0 = .init(client: slowClient(), quality: .original, transcoding: false,
                       tracks: [a.url.standardizedFileURL.path: ia, b.url.standardizedFileURL.path: ib],
                       offline: [ia.id], cacheDirectory: scratch("mix-cache"), reachable: reachable)
        }
        return (streamer, a, b, ib)
    }

    @Test("After an offline track, the next streamed one preloads at once — there's no download of the offline one to wait on")
    func preloadAfterOfflineTrack() async throws {
        let body = Data(repeating: 1, count: 3_000_000)
        SlowRangeServer.serve(body)
        let (streamer, a, b, ib) = rig(reachable: true, streamedSize: body.count)
        streamer.upcoming(current: a, next: b)
        let deadline = Date() + 1.5
        while SlowRangeServer.lock.withLock({ SlowRangeServer.requests.isEmpty }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(SlowRangeServer.lock.withLock { !SlowRangeServer.requests.isEmpty })
        #expect(streamer.holds(ib.id))
        streamer.upcoming(current: nil, next: nil)
    }

    @Test("A cached transcode doesn't stop the original being preloaded when the original is what will play")
    func preloadIgnoresACacheThatWontBeUsed() async throws {
        let body = Data(repeating: 1, count: 3_000_000)
        SlowRangeServer.serve(body)
        let (streamer, a, b, ib) = rig(reachable: true, streamedSize: body.count, hash: "lowonly")
        let cache = try #require(streamer.cache(streamer.config.withLock { $0 }))
        cache.storeTranscode(try #require(StreamCache.key(hash: "lowonly", quality: .low)), trackID: ib.id,
                             quality: .low, data: Data(count: 10), priming: 0, frames: nil)
        streamer.upcoming(current: a, next: b)
        let deadline = Date() + 1.5
        while SlowRangeServer.lock.withLock({ SlowRangeServer.requests.isEmpty }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(SlowRangeServer.lock.withLock { !SlowRangeServer.requests.isEmpty })
        streamer.upcoming(current: nil, next: nil)
    }

    @Test("While the server is away, a streamed track fails at once and reads as unplayable; an offline copy doesn't")
    func unreachableServerFailsFast() async throws {
        SlowRangeServer.serve(Data(count: 1000))
        let (streamer, a, b, _) = rig(reachable: false, streamedSize: 1000)
        #expect(streamer.canPlay(a))
        #expect(!streamer.canPlay(b))
        let began = Date()
        await #expect(throws: (any Error).self) { _ = try await streamer.open(b, at: 0) }
        #expect(Date().timeIntervalSince(began) < 0.2)
        #expect(SlowRangeServer.lock.withLock { SlowRangeServer.requests.isEmpty })
        streamer.upcoming(current: a, next: b)
        try await Task.sleep(for: .milliseconds(200))
        #expect(SlowRangeServer.lock.withLock { SlowRangeServer.requests.isEmpty }, "no preload while away")
    }
}

// MARK: - Stream cache

nonisolated(unsafe) private let flac16: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100,
                                     AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]

private func info(_ size: Int, hash: String?, format: AudioFileFormat = .flac) -> ServerStreamer.TrackInfo {
    ServerStreamer.TrackInfo(id: UUID(), format: format, fileSize: Int64(size), contentHash: hash,
                             sampleRate: 44_100, bitrate: 1000, frames: nil, duration: 5)
}

extension RemoteOriginalTests {
    @Test("A track played before comes from the cache, even after a relaunch: the same audio, no request, marked cached")
    func replayComesFromTheCache() async throws {
        let original = scratch("replay.flac")
        try write(tone(frames: 44_100 * 5), to: original, settings: flac16)
        let bytes = try Data(contentsOf: original)
        SlowRangeServer.serve(bytes)
        let t = Track(url: scratch("replay-track.flac"), title: "R", duration: 5, fileFormat: .flac)
        let i = info(bytes.count, hash: "sha256:replay")
        let dir = scratch("cache")
        func streamer() -> ServerStreamer {
            let s = ServerStreamer()
            s.config.withLock { $0 = .init(client: slowClient(), quality: .original, transcoding: false,
                                           tracks: [t.url.standardizedFileURL.path: i], cacheDirectory: dir) }
            return s
        }
        let first = streamer()
        var source: (any PCMSource)? = try await first.open(t, at: 0)
        #expect(source?.playbackSource == .streaming)
        let key = try #require(StreamCache.key(hash: "sha256:replay", quality: .original))
        let cache = try #require(first.cache(first.config.withLock { $0 }))
        let deadline = Date() + 10
        while !cache.isComplete(key), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(cache.isComplete(key))
        let heard = try readAll(source!)
        source = nil
        first.upcoming(current: nil, next: nil)

        SlowRangeServer.serve(bytes)
        let again = streamer()
        #expect(again.canPlay(t))
        let replay = try #require(try await again.open(t, at: 0))
        #expect(replay.playbackSource == .cached(.original))
        #expect(try readAll(replay) == heard)
        #expect(SlowRangeServer.lock.withLock { SlowRangeServer.requests.isEmpty }, "no request")
    }

    @Test("A track skipped partway keeps what it downloaded; playing it again asks only for the rest")
    func partialDownloadResumes() async throws {
        let body = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        SlowRangeServer.serve(body)
        let cache = StreamCache(directory: scratch("partial-cache"))
        let key = "partial-original", id = UUID(), size = Int64(body.count)
        func open() throws -> RemoteFile {
            try RemoteFile(client: slowClient(), trackID: id, size: size, file: cache.fileURL(key, quality: .original),
                           existing: cache.beginOriginal(key, trackID: id, size: size),
                           persist: { have, etag, _ in cache.saveOriginal(key, have: have, etag: etag) })
        }
        var file: RemoteFile? = try open()
        try await Task.sleep(for: .milliseconds(300))
        file?.drop()
        file = nil
        let entry = try #require(cache.entry(key))
        let stored = entry.stored
        #expect(stored > 0 && stored < size)
        // Two windows were coming at once, so there may be two runs on disk:
        // the first missing byte is where the first run stops.
        let gap = try #require(entry.ranges.first { $0[0] == 0 })[1]

        SlowRangeServer.serve(body)
        let resumed = try open()
        try await Task.sleep(for: .milliseconds(100))
        let first = SlowRangeServer.lock.withLock { SlowRangeServer.requests.first }
        #expect(first?.hasPrefix("bytes=\(gap)-") == true, "picks up at \(gap), asked \(first ?? "nothing")")
        let head = try await Task.detached {
            var b = [UInt8](repeating: 0, count: 100)
            _ = try resumed.read(into: &b, at: 0, count: 100)
            return Data(b)
        }.value
        #expect(head == body.prefix(100))
        resumed.drop()
    }
}

extension RemoteOriginalTests {
    @Test("Over a link with a round trip per request, the download keeps the link busy and measures its real rate")
    func pipelinedWindowsMeasureTheLink() async throws {
        let body = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })
        SlowRangeServer.serve(body)
        SlowRangeServer.lock.withLock { SlowRangeServer.latency = 0.2; SlowRangeServer.sharedLink = true }
        let rates = OSAllocatedUnfairLock(initialState: [Double]())
        let file = try RemoteFile(client: slowClient(), trackID: UUID(), size: Int64(body.count), file: scratch("pipe.bin"),
                                  onSpeed: { r in rates.withLock { $0.append(r) } })
        let deadline = Date() + 15
        while !file.isComplete, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(file.isComplete)
        let truth = SlowRangeServer.lock.withLock { Double(SlowRangeServer.sent) / SlowRangeServer.sending }
        let measured = try #require(rates.withLock { $0.last })
        #expect(measured > truth * 0.75, "measured \(Int(measured)) B/s of \(Int(truth))")
        #expect(SlowRangeServer.lock.withLock { SlowRangeServer.maxOpen } <= 2)
        file.drop()
    }
}

extension RemoteOriginalTests {
    @Test("With Automatic quality, a slow response alone doesn't give up a read; the engine's low-buffer signal does")
    func waitingAloneDoesNotDropQuality() async throws {
        let body = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        SlowRangeServer.serve(body)
        let file = try RemoteFile(client: slowClient(), trackID: UUID(), size: Int64(body.count), file: scratch("auto.bin"))
        file.stallThrows = true
        try await Task.sleep(for: .milliseconds(50))
        SlowRangeServer.lock.withLock { SlowRangeServer.latency = 2.5 }
        // Far ahead of the download: a new request, answered 2.5 s later.
        let read = try await Task.detached {
            var b = [UInt8](repeating: 0, count: 100)
            _ = try file.read(into: &b, at: 1_900_000, count: 100)
            return Data(b)
        }.value
        #expect(read == body.subdata(in: 1_900_000..<1_900_100))

        // Now the engine says its buffer is low while a read waits: it gives up.
        let waiter = Task.detached {
            var b = [UInt8](repeating: 0, count: 100)
            _ = try file.read(into: &b, at: 1_000_000, count: 100)
        }
        try await Task.sleep(for: .milliseconds(300))
        file.stalled()
        await #expect(throws: (any Error).self) { try await waiter.value }
        file.drop()
    }
}

@Test("Past its limit the cache drops the least recently played first, never one in use")
func streamCacheEvictsOldestNotInUse() throws {
    let cache = StreamCache(directory: scratch("evict-cache"), limit: 1000)
    func put(_ k: String) {
        cache.storeTranscode(k, trackID: UUID(), quality: .high, data: Data(count: 400), priming: 0, frames: nil)
        Thread.sleep(forTimeInterval: 0.01)
    }
    put("a-high"); put("b-high"); put("c-high")
    #expect(cache.entry("a-high") == nil)
    #expect(cache.entry("b-high") != nil && cache.entry("c-high") != nil)
    cache.lease("b-high")
    put("d-high")
    #expect(cache.entry("b-high") != nil, "in use")
    #expect(cache.entry("c-high") == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.fileURL("c-high", quality: .high).path))
    #expect(cache.totalStored <= 1000)
}

@Test("A track made available offline loses its cached copy")
func offlineCopyReplacesCachedStream() throws {
    let streamer = ServerStreamer()
    streamer.config.withLock { $0 = .init(cacheDirectory: scratch("offline-cache")) }
    let cache = try #require(streamer.cache(streamer.config.withLock { $0 }))
    let id = UUID()
    cache.storeTranscode("x-high", trackID: id, quality: .high, data: Data(count: 10), priming: 0, frames: nil)
    #expect(cache.entry("x-high") != nil)
    streamer.setOffline([id])
    #expect(cache.entry("x-high") == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.fileURL("x-high", quality: .high).path))
}

@Test("A cached transcode plays with no server, trimmed as streamed; a lower one isn't used when better is wanted")
func cachedTranscodePlays() async throws {
    let frames = 44_100 * 2
    let url = scratch("cached.aac")
    try write(tone(frames: frames), to: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
    let adts = try Data(contentsOf: url)
    let t = Track(url: scratch("cached-track.flac"), title: "C", duration: 2, fileFormat: .flac)
    let i = info(5_000_000, hash: "cachedtx")
    let streamer = ServerStreamer()
    streamer.config.withLock { $0 = .init(client: slowClient(), quality: .normal, transcoding: true,
                                          tracks: [t.url.standardizedFileURL.path: i],
                                          cacheDirectory: scratch("tx-cache"), reachable: false) }
    let cache = try #require(streamer.cache(streamer.config.withLock { $0 }))
    let key = try #require(StreamCache.key(hash: "cachedtx", quality: .normal))
    cache.storeTranscode(key, trackID: i.id, quality: .normal, data: adts, priming: applePriming, frames: frames)

    #expect(streamer.canPlay(t))
    let source = try #require(try await streamer.open(t, at: 0))
    #expect(source.playbackSource == .cached(.normal))
    #expect(try readAll(source).count == frames)

    // Reachable and wanting High: Normal isn't good enough, so it isn't used.
    streamer.config.withLock { $0.quality = .high; $0.reachable = true }
    let picked = try await Task.detached { () -> PlaybackSource? in
        try? await withThrowingTaskGroup(of: PlaybackSource?.self) { group in
            group.addTask { try await streamer.open(t, at: 0)?.playbackSource }
            group.addTask { try await Task.sleep(for: .milliseconds(300)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }.value
    #expect(picked != .cached(.normal))
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

// MARK: - History per library

@Test("Another library's history brought to a server keeps only plays of the server's songs, under its IDs")
func importedHistoryMatchesServerTracks() throws {
    let json = #"""
    { "id": "9f1c2b3a-4d5e-4f60-8a7b-0c1d2e3f4a5b", "relativePath": "Steely Dan/Aja/01 Black Cow.flac",
      "format": "flac", "fileSize": 1, "contentHash": null, "tagFingerprint": "ab",
      "title": "Black Cow", "artist": "Steely Dan", "album": "Aja",
      "secondaryGenres": [], "isCompilation": false, "isMixCompilation": false, "hasCueSheet": false,
      "dateAdded": "2026-01-02T03:04:05Z", "modified": "2026-01-02T03:04:05Z" }
    """#
    let server = try ServerClient.decoder.decode(ServerTrack.self, from: Data(json.utf8))
    let local = UUID()
    let aja = PlayEvent(date: .now, trackID: local, title: "Black Cow", artist: "steely dan", albumID: "Steely Dan|Aja",
                        album: "Aja", secondsListened: 300, counted: true)
    let other = PlayEvent(date: .now, trackID: UUID(), title: "niteharts", artist: "ISOxo ; Knock2", albumID: "ISOxo|niteharts",
                          album: "niteharts", secondsListened: 60, counted: true)
    let contexts = [RecentContext(kind: .album, targetID: "Steely Dan|Aja", title: "Aja", subtitle: "", date: .now),
                    RecentContext(kind: .album, targetID: "ISOxo|niteharts", title: "niteharts", subtitle: "", date: .now),
                    RecentContext(kind: .playlist, targetID: UUID().uuidString, title: "Mine", subtitle: "", date: .now)]
    let (events, kept) = HistorySync.matched(([aja, other], contexts), to: [server])
    #expect(events.map(\.trackID) == [server.id])
    #expect(events.first?.id == aja.id, "the same event, so posting it twice changes nothing")
    #expect(kept.map(\.targetID) == ["Steely Dan|Aja"])
}

@MainActor
@Test("Stats count only the plays a library's filter accepts; the history keeps them all")
func statsFollowTheLibrary() {
    let store = ListeningStore(librariesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let mine = UUID(), stray = UUID()
    store.merge(events: [
        PlayEvent(date: .now, trackID: mine, title: "Black Cow", artist: "Steely Dan", secondsListened: 300, counted: true),
        PlayEvent(date: .now, trackID: stray, title: "niteharts", artist: "ISOxo ; Knock2", secondsListened: 60, counted: true),
    ], contexts: [])
    var known: Set<UUID> = [mine]
    store.belongs = { known.contains($0.trackID) }
    #expect(store.events.map(\.trackID) == [mine])
    #expect(!store.topArtists(limit: 5, resolver: ArtistResolver(tracks: [])).contains { $0.name == "Knock2" })
    known.insert(stray)
    store.refilter()
    #expect(store.events.count == 2, "a song that arrives later counts its earlier plays")
    store.belongs = nil
    #expect(store.events.count == 2)
}

@Test("A cover over the server's 10 MiB is re-encoded to fit; one within it is sent as is")
func coverFitsTheServer() {
    let side = 3000
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: side * 3, bitsPerPixel: 24)!
    arc4random_buf(rep.bitmapData!, side * side * 3)
    let png = rep.representation(using: .png, properties: [:])!
    #expect(png.count > 10 << 20, "a noisy 3000 px PNG is over the limit")
    let fitted = TagEdit.fitForServer(png)
    #expect(fitted.count <= 10 << 20)
    let image = NSBitmapImageRep(data: fitted)
    #expect(image?.pixelsWide == side, "same size, only re-encoded")
    let small = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5])!
    #expect(TagEdit.fitForServer(small) == small)
}
