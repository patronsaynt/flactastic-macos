@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import flactastic

// MARK: - Media HTTP server

@Suite(.serialized) struct MediaHTTPServerTests {

    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cast-fixture-\(UUID().uuidString).flac")
        let bytes = (0..<4096).map { UInt8($0 % 251) }
        try Data(bytes).write(to: url)
        return url
    }

    private func get(_ url: URL, range: String? = nil, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func servesRegisteredFileWithRangesAndRejectsEverythingElse() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let expected = try Data(contentsOf: fixture)

        let server = MediaHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let path = server.register(MediaResource(body: .file(fixture), mimeType: "audio/flac", isAudio: true),
                                   fileExtension: "flac")
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let url = try #require(URL(string: path, relativeTo: base))

        let (full, fullResponse) = try await get(url)
        #expect(fullResponse.statusCode == 200)
        #expect(full == expected)
        #expect(fullResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(fullResponse.value(forHTTPHeaderField: "Content-Type") == "audio/flac")

        let (part, partResponse) = try await get(url, range: "bytes=100-199")
        #expect(partResponse.statusCode == 206)
        #expect(part == expected.subdata(in: 100..<200))
        #expect(partResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/4096")

        let (headBody, headResponse) = try await get(url, method: "HEAD")
        #expect(headResponse.statusCode == 200)
        #expect(headBody.isEmpty)
        #expect(headResponse.value(forHTTPHeaderField: "Content-Length") == "4096")

        let (_, tooFar) = try await get(url, range: "bytes=5000-")
        #expect(tooFar.statusCode == 416)

        let (_, unknown) = try await get(try #require(URL(string: "/t/\(String(repeating: "0", count: 32)).flac", relativeTo: base)))
        #expect(unknown.statusCode == 404)

        let (_, traversal) = try await get(try #require(URL(string: "/t/../../etc/passwd", relativeTo: base)))
        #expect(traversal.statusCode == 404)
    }

    @Test func registryEvictsOldestTokens() {
        let server = MediaHTTPServer()
        let first = server.register(MediaResource(body: .data(Data([1])), mimeType: "image/png", isAudio: false),
                                    fileExtension: "png")
        #expect(server.resource(forPath: first) != nil)
        for _ in 0..<MediaHTTPServer.capacity {
            _ = server.register(MediaResource(body: .data(Data([2])), mimeType: "image/png", isAudio: false),
                                fileExtension: "png")
        }
        #expect(server.resource(forPath: first) == nil)
        #expect(server.resource(forPath: "/x/\(String(repeating: "a", count: 32)).png") == nil)
    }
}

// MARK: - Engine remote mode

private final class SilentGraph: AudioGraphProtocol, @unchecked Sendable {
    let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    func prepare() throws {}
    func reprepare() {}
    func schedule(_ buffer: AVAudioPCMBuffer, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {}
    func play() {}
    func pause() {}
    func flush() {}
    var isNodePlaying: Bool { false }
    func currentPlayerSampleTime() -> AVAudioFramePosition? { nil }
    func setOutputVolume(_ volume: Float) {}
    func onConfigurationChange(_ handler: @escaping @Sendable () -> Void) {}
    func applyOutput(_ config: AudioOutputConfig) throws {}
    var isInSyncWithDevice: Bool { true }
    func installAnalysisTap(bufferSize: AVAudioFrameCount,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    func removeAnalysisTap() {}
}

@MainActor
private final class RecordingTarget: RemotePlaybackTarget {
    enum Call: Equatable {
        case load(String, next: String?, startAt: TimeInterval, autoplay: Bool)
        case play, pause
        case seek(TimeInterval)
        case next(String?)
        case volume(Float)
    }
    var calls: [Call] = []

    func load(_ track: Track, next: Track?, startAt: TimeInterval, autoplay: Bool) {
        calls.append(.load(track.title, next: next?.title, startAt: startAt, autoplay: autoplay))
    }
    func play() { calls.append(.play) }
    func pause() { calls.append(.pause) }
    func seek(to seconds: TimeInterval) { calls.append(.seek(seconds)) }
    func setNext(_ track: Track?) { calls.append(.next(track?.title)) }
    func setVolume(_ volume: Float) { calls.append(.volume(volume)) }
}

@MainActor
private func makeQueue(_ titles: [String]) -> [Track] {
    titles.map { Track(url: URL(fileURLWithPath: "/m/\($0).flac"), title: $0, duration: 180, fileFormat: .flac) }
}

@MainActor
@Test func attachingHandsTheCurrentTrackToTheRemote() {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setQueue(makeQueue(["A", "B", "C"]), startAt: 1)
    let target = RecordingTarget()
    engine.attachRemote(target, volume: 0.4)

    #expect(engine.isRemote)
    #expect(engine.volume == 0.4)
    #expect(target.calls == [.load("B", next: "C", startAt: 0, autoplay: false)])
}

@MainActor
@Test func transportCallsForwardToTheRemote() {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setQueue(makeQueue(["A", "B"]), startAt: 0)
    let target = RecordingTarget()
    engine.attachRemote(target, volume: nil)
    target.calls.removeAll()

    engine.play()
    engine.seek(to: 42)
    engine.setVolume(0.5)
    engine.pause()
    engine.next()

    #expect(target.calls == [
        .play, .seek(42), .volume(0.5), .pause,
        .load("B", next: nil, startAt: 0, autoplay: false), .play,
    ])
    #expect(engine.currentIndex == 1)
    #expect(engine.isPlaying)
}

@MainActor
@Test func gaplessAdvanceMovesTheIndexAndRearmsNext() {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setQueue(makeQueue(["A", "B", "C"]), startAt: 0)
    let target = RecordingTarget()
    engine.attachRemote(target, volume: nil)
    target.calls.removeAll()

    engine.remoteDidAdvance()
    #expect(engine.currentTrack?.title == "B")
    #expect(target.calls == [.next("C")])

    engine.remoteDidAdvance()
    #expect(engine.currentTrack?.title == "C")
    #expect(target.calls.last == .next(nil))
}

@MainActor
@Test func repeatOneArmsTheSameTrackAndQueueEditsRearm() {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setQueue(makeQueue(["A", "B"]), startAt: 0)
    let target = RecordingTarget()
    engine.attachRemote(target, volume: nil)
    target.calls.removeAll()

    engine.isRepeatOne = true
    #expect(target.calls.last == .next("A"))
    engine.remoteDidAdvance()
    #expect(engine.currentTrack?.title == "A")

    engine.isRepeatOne = false
    engine.insertTracks(makeQueue(["X"]), at: 1)
    #expect(target.calls.last == .next("X"))
}

@MainActor
@Test func reachingTheEndWithoutGaplessLoadsNextThenFinishes() {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setQueue(makeQueue(["A", "B"]), startAt: 0)
    let target = RecordingTarget()
    engine.attachRemote(target, volume: nil)
    engine.play()
    target.calls.removeAll()

    engine.remoteDidReachEnd()
    #expect(engine.currentTrack?.title == "B")
    #expect(target.calls == [.load("B", next: nil, startAt: 0, autoplay: true)])

    engine.remoteDidReachEnd()
    #expect(!engine.isPlaying)
    #expect(engine.currentTime == 180)
}

@MainActor
@Test func detachingRestoresLocalVolumeAndPosition() {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setVolume(0.8)
    engine.setQueue(makeQueue(["A"]), startAt: 0)
    let target = RecordingTarget()
    engine.attachRemote(target, volume: 0.2)
    engine.remoteDidReport(position: 61, isPlaying: false)
    #expect(engine.currentTime == 61)

    engine.detachRemote(resumePlaying: false)
    #expect(!engine.isRemote)
    #expect(engine.volume == 0.8)
    #expect(engine.currentTime == 61)
    #expect(!engine.isPlaying)
}

// MARK: - Transcoder

@Test func transcoderDownsamplesToSixteenBitFlac() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cast-transcode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // One second of a 1 kHz tone at 96 kHz.
    let source = dir.appendingPathComponent("tone.wav")
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 2, interleaved: false))
    do {
        let file = try AVAudioFile(forWriting: source, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for channel in 0..<2 {
            for i in 0..<96_000 { buffer.floatChannelData![channel][i] = sin(Float(i) * 2 * .pi * 1000 / 96_000) * 0.5 }
        }
        try file.write(from: buffer)
    }

    let output = dir.appendingPathComponent("out.flac")
    try Transcoder.transcode(source: source, to: output, container: .flac, sampleRate: 44_100, bitDepth: 16)

    let result = try AVAudioFile(forReading: output)
    #expect(result.fileFormat.sampleRate == 44_100)
    #expect(result.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC)
    #expect(result.fileFormat.streamDescription.pointee.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData)
    #expect(abs(Int(result.length) - 44_100) < 64)
}

@MainActor
@Test func remoteClockWaitsForTheDeviceToStartPlaying() async throws {
    let engine = PlayerEngine(graph: SilentGraph())
    engine.setQueue(makeQueue(["A"]), startAt: 0)
    engine.attachRemote(RecordingTarget(), volume: nil)
    engine.play()
    #expect(engine.isAwaitingRemoteStart)

    // The speaker is still buffering: the seek bar must not move.
    try await Task.sleep(for: .milliseconds(300))
    #expect(engine.currentTime == 0)

    engine.remoteDidReport(position: 0, isPlaying: true)
    #expect(!engine.isAwaitingRemoteStart)
    try await Task.sleep(for: .milliseconds(300))
    #expect(engine.currentTime > 0.1)

    // A seek freezes the clock again until the device confirms it.
    engine.seek(to: 90)
    #expect(engine.isAwaitingRemoteStart)
    try await Task.sleep(for: .milliseconds(200))
    #expect(engine.currentTime == 90)
}
