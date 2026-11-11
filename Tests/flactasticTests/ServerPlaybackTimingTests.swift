@preconcurrency import AVFoundation
import Foundation
import os
import Testing
@testable import flactastic

// Playback against a running server (FLACTASTIC_TEST_SERVER etc., as
// ServerIntegrationTests), through the real engine and streamer. "output" is
// when the engine starts the node with audio queued; the audio device adds
// its own fixed latency after that. FLACTASTIC_TEST_SHAPE, when set, names
// the link the caller shaped on the server (tc netem); it only labels rows.

/// An output whose clock runs while it plays. Buffers are consumed in order,
/// in real time while it plays, or at once while `instant` is set (to decode
/// a join quickly).
private final class TestGraph: AudioGraphProtocol, @unchecked Sendable {
    typealias Done = @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let lock = NSLock()
    private var startedAt: Date?
    private var played: Double = 0
    nonisolated(unsafe) var instant = false
    private var scheduled: Int64 = 0
    /// Where the queued audio ends on the clock, and what ends when.
    private var queuedEnd: Double = 0
    private var pending: [(end: Double, done: Done)] = []
    private var timer: DispatchSourceTimer?
    var scheduledFrames: Int64 { lock.withLock { scheduled } }
    func prepare() throws {}
    func reprepare() {}
    private var clock: Double { played + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    func schedule(_ buffer: AVAudioPCMBuffer, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping Done) {
        if instant {
            lock.withLock { scheduled += Int64(buffer.frameLength) }
            DispatchQueue.global().async { completionHandler(.dataConsumed) }
            return
        }
        lock.withLock {
            scheduled += Int64(buffer.frameLength)
            queuedEnd = max(queuedEnd, clock) + Double(buffer.frameLength) / 44_100
            pending.append((queuedEnd, completionHandler))
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now(), repeating: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.consume() }
            t.resume()
            timer = t
        }
    }
    private func consume() {
        let done: [Done] = lock.withLock {
            let now = clock
            let ended = pending.prefix { $0.end <= now }
            pending.removeFirst(ended.count)
            return ended.map(\.done)
        }
        done.forEach { $0(.dataConsumed) }
    }
    func play() { lock.withLock { if startedAt == nil { startedAt = Date() } } }
    func pause() { lock.withLock { if let s = startedAt { played += Date().timeIntervalSince(s); startedAt = nil } } }
    func flush() {
        let done: [Done] = lock.withLock {
            startedAt = nil; played = 0; scheduled = 0; queuedEnd = 0
            defer { pending = [] }
            return pending.map(\.done)
        }
        done.forEach { $0(.dataConsumed) }
    }
    var isNodePlaying: Bool { lock.withLock { startedAt != nil } }
    func currentPlayerSampleTime() -> AVAudioFramePosition? {
        lock.withLock { AVAudioFramePosition(clock * 44_100) }
    }
    func setOutputVolume(_ volume: Float) {}
    func onConfigurationChange(_ handler: @escaping @Sendable () -> Void) {}
    func applyOutput(_ config: AudioOutputConfig) throws {}
    var isInSyncWithDevice: Bool { true }
    func installAnalysisTap(bufferSize: AVAudioFrameCount, _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    func removeAnalysisTap() {}
}

/// A signed-in streamer over the server's tracks, and an engine using it.
@MainActor
private struct Rig {
    let client: ServerClient
    let streamer: ServerStreamer
    let engine: PlayerEngine
    let graph: TestGraph
    let tracks: [String: Track]
    let infos: [String: ServerStreamer.TrackInfo]
    let root: URL

    static func make(quality: StreamQuality = .original) async throws -> Rig {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(ServerAddress(typed: env["FLACTASTIC_TEST_SERVER"]!))
        let pair = try #require(env["FLACTASTIC_TEST_USERS"]?.split(separator: ",").first?.split(separator: ":", maxSplits: 1))
        let (_, pin) = try await ServerSession.probe(address)
        let client = ServerClient(address: address, pin: pin)
        struct Login: Encodable { let username, password, deviceName, deviceKind: String }
        client.token = try await client.json(LoginResponse.self, "POST", "v2/auth/login",
            body: Login(username: String(pair[0]), password: String(pair[1]), deviceName: "Playback test", deviceKind: "mac")).token
        var all: [ServerTrack] = [], since = 0, more = true
        while more {
            let page = try await client.json(TracksPage.self, "GET", "v2/tracks", query: [URLQueryItem(name: "since", value: String(since))])
            all += page.tracks; since = page.seq; more = page.more
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID().uuidString)", isDirectory: true)
        var infos: [String: ServerStreamer.TrackInfo] = [:], byPath: [String: ServerStreamer.TrackInfo] = [:], tracks: [String: Track] = [:]
        for t in all {
            guard let app = t.appTrack(root: root), let format = AudioFileFormat(rawValue: t.format) else { continue }
            let info = ServerStreamer.TrackInfo(id: t.id, format: format, fileSize: t.fileSize, contentHash: t.contentHash,
                                                sampleRate: Double(t.sampleRate ?? 44_100), bitrate: t.bitrate ?? 0,
                                                frames: t.frames, duration: t.duration)
            byPath[app.url.standardizedFileURL.path] = info
            infos[t.title] = info
            tracks[t.title] = app
        }
        let streamer = ServerStreamer()
        let config = ServerStreamer.Config(client: client, quality: quality, transcoding: true, tracks: byPath,
                                           cacheDirectory: root.appendingPathComponent("cache", isDirectory: true))
        streamer.config.withLock { $0 = config }
        let graph = TestGraph()
        let engine = PlayerEngine(graph: graph)
        engine.sourceOpener = { track, seconds in try await streamer.open(track, at: seconds) }
        engine.upcoming = { streamer.upcoming(current: $0, next: $1) }
        engine.stalled = { streamer.stalled() }
        return Rig(client: client, streamer: streamer, engine: engine, graph: graph, tracks: tracks, infos: infos, root: root)
    }

    /// Stops playback. The device stays signed in: logging out while this
    /// test's last requests drain would count them against the IP (§6).
    func close() async {
        engine.setQueue([], startAt: 0)
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits for the current action's audio at the output; its steps in ms.
    /// `since` is what had finished before the action, when it may already be done.
    func output(timeout: Double = 30, since: [String: Double]? = nil) async throws -> [String: Double] {
        let before = since ?? PlaybackTrace.lastFinished
        let deadline = Date().addingTimeInterval(timeout)
        while PlaybackTrace.lastFinished == before, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        return PlaybackTrace.lastFinished == before ? [:] : PlaybackTrace.lastFinished
    }
}

private func row(_ name: String, _ m: [String: Double]) {
    let f = { (k: String) in m[k].map { String(format: "%6.0f", $0) } ?? "     –" }
    let shape = ProcessInfo.processInfo.environment["FLACTASTIC_TEST_SHAPE"] ?? "unshaped"
    print("TIMING [\(shape)] \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) request\(f("request")) headers\(f("headers")) decoded\(f("decoded")) output\(f("output")) ms")
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FLACTASTIC_TEST_SERVER"] != nil), .serialized)
@MainActor
struct ServerPlaybackTimingTests {
    @Test("Targets: start, skip to a preloaded track, seek inside and outside the buffer")
    func targets() async throws {
        for quality in [StreamQuality.original, .normal] {
            let rig = try await Rig.make(quality: quality)
            let a = try #require(rig.tracks["FLAC 16-44"]), b = try #require(rig.tracks["ALAC"])
            rig.engine.setQueue([a, b], startAt: 0)
            rig.engine.play()
            row("\(quality.rawValue): start", try await rig.output())
            try await Task.sleep(for: .seconds(3))
            rig.engine.seek(to: 1)
            row("\(quality.rawValue): seek inside buffer", try await rig.output())
            rig.engine.seek(to: 200)
            row("\(quality.rawValue): seek outside buffer", try await rig.output())
            // Let the next track preload (ten seconds in hand), then skip to it.
            let deadline = Date().addingTimeInterval(20)
            while !rig.streamer.holds(rig.infos["ALAC"]!.id), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .seconds(1))
            rig.engine.next()
            row("\(quality.rawValue): skip to preloaded", try await rig.output())
            await rig.close()
        }
    }

    @Test("Seek accuracy: after a seek the audio matches the file at that time", arguments: ["FLAC 16-44", "MP3", "ALAC", "WAV"])
    func seekAccuracy(title: String) async throws {
        let rig = try await Rig.make()
        let info = try #require(rig.infos[title])
        let (whole, _, _) = try await ServerStreamer.fetch(rig.client, info.id, 0..<info.fileSize, nil)
        let ext = info.format == .alac || info.format == .aac ? "m4a" : info.format.rawValue
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        let localURL = rig.root.appendingPathComponent("local.\(ext)")
        try whole.write(to: localURL)
        let local = try AVAudioFile(forReading: localURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let remote = try RemoteFile(client: rig.client, trackID: info.id, size: info.fileSize,
                                    file: rig.root.appendingPathComponent("remote.\(ext)"))
        let source = try await Task.detached { try RemoteAudioSource(remote, format: info.format) }.value
        let target = AVAudioFramePosition(150 * local.processingFormat.sampleRate)
        @Sendable func samples(_ s: any PCMSource) throws -> [Float] {
            s.framePosition = target
            let buffer = AVAudioPCMBuffer(pcmFormat: s.processingFormat, frameCapacity: 4096)!
            try s.read(into: buffer, frameCount: 4096)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let theirs = try await Task.detached { try samples(source) }.value
        #expect(theirs.count == 4096)
        #expect(theirs == (try samples(local)), "\(title) at 150 s")
        remote.drop()
        await rig.close()
    }

    @Test("Gapless across a preloaded join, at Original and transcoded", arguments: [StreamQuality.original, .normal])
    func gaplessJoin(quality: StreamQuality) async throws {
        let rig = try await Rig.make(quality: quality)
        let a = try #require(rig.tracks["Tone A"]), b = try #require(rig.tracks["FLAC 16-44"])
        rig.engine.setQueue([a, b], startAt: 0)
        rig.engine.play()
        _ = try await rig.output()
        let deadline = Date().addingTimeInterval(20)
        while !rig.streamer.holds(rig.infos["FLAC 16-44"]!.id), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.streamer.holds(rig.infos["FLAC 16-44"]!.id), "the next track was preloaded")
        // Now decode everything as fast as it comes: the join must add nothing.
        rig.graph.instant = true
        let expected = Int64(12 * 44_100 + 300 * 44_100)
        let end = Date().addingTimeInterval(90)
        while rig.graph.scheduledFrames < expected, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.graph.scheduledFrames == expected, "every frame of both tracks and nothing between: \(rig.graph.scheduledFrames)")
        await rig.close()
    }

    @Test("Scrubbing back and forth for ten seconds: one request at a time, lands on the last position",
          arguments: [StreamQuality.original, .normal])
    func scrubbing(quality: StreamQuality) async throws {
        let rig = try await Rig.make(quality: quality)
        let track = try #require(rig.tracks["FLAC 16-44"])
        rig.engine.setQueue([track], startAt: 0)
        rig.engine.play()
        _ = try await rig.output()
        let peak = OSAllocatedUnfairLock(initialState: 0)
        let watch = Task.detached {
            while !Task.isCancelled {
                let n = StreamTask.inFlight.withLock { $0 }
                peak.withLock { $0 = max($0, n) }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        var last = 0.0, before: [String: Double] = [:]
        for i in 0..<50 {
            last = Double.random(in: 5...290)
            if i == 49 { before = PlaybackTrace.lastFinished }
            rig.engine.seek(to: last)
            if i < 49 { try await Task.sleep(for: .milliseconds(200)) }
        }
        let landed = try await rig.output(since: before)
        watch.cancel()
        #expect(!landed.isEmpty, "audio after the last seek")
        #expect(abs(rig.engine.currentTime - last) < 1.5, "at \(rig.engine.currentTime), last seek \(last)")
        #expect(rig.engine.currentTrack?.url == track.url, "no error moved it on")
        #expect(peak.withLock { $0 } <= 1, "requests in flight peaked at \(peak.withLock { $0 })")
        await rig.close()
    }

    @Test("Skipping ten tracks quickly leaks no requests, and the clock never shows the previous track's position")
    func skippingTen() async throws {
        let rig = try await Rig.make(quality: .normal)
        let queue = rig.tracks.values.filter { ($0.duration ?? 0) > 5 }.sorted { $0.title < $1.title }
        rig.engine.setQueue(Array(queue.prefix(11)), startAt: 0)
        rig.engine.play()
        _ = try await rig.output()
        try await Task.sleep(for: .seconds(2))
        for _ in 0..<10 {
            rig.engine.next()
            #expect(rig.engine.currentTime < 0.5, "reset with the track")
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await rig.output()
        try await Task.sleep(for: .seconds(2))
        #expect(StreamTask.inFlight.withLock { $0 } <= 2, "the current track and one preload at most")
        await rig.close()
    }

    /// Needs FLACTASTIC_TEST_SLOW and a caller that shapes the server like 3G
    /// or DSL, then lifts the shaping when /tmp/flactastic-lift-shaping appears and
    /// creates /tmp/flactastic-shaping-lifted.
    @Test("Auto on a slow link: steps down after one stall at most, plays on, steps up when the link is back")
    func autoOnASlowLink() async throws {
        guard ProcessInfo.processInfo.environment["FLACTASTIC_TEST_SLOW"] != nil else { return }
        let rig = try await Rig.make(quality: .auto)
        let first = try #require(rig.tracks["FLAC 24-192"])
        let stallsBefore = RemoteFile.stalls.withLock { $0 }
        rig.engine.setQueue([first], startAt: 0)
        rig.engine.play()
        row("auto, slow link: start", try await rig.output(timeout: 60))
        try await Task.sleep(for: .seconds(8))
        let stalls = RemoteFile.stalls.withLock { $0 } - stallsBefore
        print("AUTO after start: \(String(describing: rig.engine.currentSource)), stalls \(stalls)")
        if case .transcode? = rig.engine.currentSource {} else {
            Issue.record("expected a transcode on a slow link, got \(String(describing: rig.engine.currentSource))")
        }
        #expect(stalls <= 1, "one stall at most")
        let ask = "/tmp/flactastic-lift-shaping", done = "/tmp/flactastic-shaping-lifted"
        FileManager.default.createFile(atPath: ask, contents: nil)
        let lifted = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done), Date() < lifted { try await Task.sleep(for: .milliseconds(100)) }
        try? FileManager.default.removeItem(atPath: ask)
        try? FileManager.default.removeItem(atPath: done)
        try await Task.sleep(for: .seconds(3))
        rig.engine.appendTracks([try #require(rig.tracks["FLAC 16-44"])])
        try await Task.sleep(for: .seconds(2))
        rig.engine.next()
        _ = try await rig.output()
        print("AUTO on the next track: \(String(describing: rig.engine.currentSource))")
        #expect(rig.engine.currentSource == .streaming, "back to the original on the next track")
        await rig.close()
    }
}
