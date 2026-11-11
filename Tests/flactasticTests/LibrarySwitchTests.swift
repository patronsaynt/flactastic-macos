@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import flactastic

private final class QuietGraph: AudioGraphProtocol, @unchecked Sendable {
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
@Test("Opening a different library stops playback and empties the queue; reopening the same one doesn't")
func switchingLibrariesResetsThePlayer() {
    let player = PlayerState(graph: QuietGraph())
    let library = LibraryStore()
    library.onLibraryChange = { player.resetForLibrarySwitch() }
    library.openServer(root: URL(fileURLWithPath: "/tmp/a", isDirectory: true), tracks: [])

    let tracks = (1...3).map { Track(url: URL(fileURLWithPath: "/tmp/a/\($0).flac"), title: "\($0)", duration: 60, fileFormat: .flac) }
    player.startFreshQueue(tracks, startAt: 1)
    player.engine.pause()
    #expect(player.currentTrack?.title == "2")

    library.openServer(root: URL(fileURLWithPath: "/tmp/a", isDirectory: true), tracks: [])
    #expect(player.currentTrack?.title == "2", "the same library keeps its queue")

    library.openServer(root: URL(fileURLWithPath: "/tmp/b", isDirectory: true), tracks: [])
    #expect(player.currentTrack == nil)
    #expect(player.queue.isEmpty)
    #expect(!player.isPlaying)

    player.startFreshQueue(tracks, startAt: 0)
    library.close()
    #expect(player.currentTrack == nil)
}

// MARK: - The scrubber while a stream is late

/// An output whose clock runs on wall time while the node plays, like the
/// real node: it keeps counting even with nothing scheduled.
private final class WallClockGraph: AudioGraphProtocol, @unchecked Sendable {
    let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    var outputLatency: TimeInterval { 0.2 }
    private var startedAt: Date?
    private var accumulated: Double = 0
    func prepare() throws {}
    func reprepare() {}
    func schedule(_ buffer: AVAudioPCMBuffer, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {}
    func play() { if startedAt == nil { startedAt = Date() } }
    func pause() { if let s = startedAt { accumulated += Date().timeIntervalSince(s); startedAt = nil } }
    func flush() { startedAt = nil; accumulated = 0 }
    var isNodePlaying: Bool { startedAt != nil }
    func currentPlayerSampleTime() -> AVAudioFramePosition? {
        AVAudioFramePosition((accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)) * 44_100)
    }
    func setOutputVolume(_ volume: Float) {}
    func onConfigurationChange(_ handler: @escaping @Sendable () -> Void) {}
    func applyOutput(_ config: AudioOutputConfig) throws {}
    var isInSyncWithDevice: Bool { true }
    func installAnalysisTap(bufferSize: AVAudioFrameCount,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    func removeAnalysisTap() {}
}

/// Five seconds of silence.
private final class SilenceSource: PCMSource {
    let processingFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let length: AVAudioFramePosition = 5 * 44_100
    var framePosition: AVAudioFramePosition = 0
    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        let n = min(AVAudioFramePosition(frames), length - framePosition)
        buffer.frameLength = AVAudioFrameCount(max(0, n))
        framePosition += max(0, n)
    }
}

@MainActor
@Test("While a stream is still opening, the clock waits: the scrubber doesn't run ahead of the audio")
func scrubberWaitsForALateStream() async throws {
    let engine = PlayerEngine(graph: WallClockGraph())
    engine.sourceOpener = { _, _ in
        try await Task.sleep(for: .milliseconds(600))
        return SilenceSource()
    }
    let track = Track(url: URL(fileURLWithPath: "/srv/a.flac"), title: "A", duration: 5, fileFormat: .flac)
    engine.setQueue([track], startAt: 0)
    engine.play()
    try await Task.sleep(for: .milliseconds(500))
    #expect(engine.currentTime < 0.1, "nothing has played yet")
    #expect(engine.isHolding, "waiting on the stream, so the record and lyrics hold too")
    try await Task.sleep(for: .milliseconds(700))
    // ~0.6 s after the audio arrived; without the hold this would read ~1.2 s.
    #expect(engine.currentTime < 0.85)
    let deadline = Date().addingTimeInterval(3)
    while engine.currentTime == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(engine.currentTime > 0, "the clock runs once audio is queued")
    #expect(!engine.isHolding)
    engine.pause()
}


@MainActor
@Test("Lyrics and chapters use heard time: the clock less the output's latency")
func heardTimeSubtractsLatency() {
    let player = PlayerState(graph: WallClockGraph())
    player.currentTime = 10
    #expect(abs(player.heardTime - 9.8) < 0.0001)
    player.currentTime = 0.1
    #expect(player.heardTime == 0)
}


// MARK: - The source mark

/// Half a second of silence, marked as coming from `source`.
private final class MarkedSource: PCMSource {
    let playbackSource: PlaybackSource?
    let processingFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let length: AVAudioFramePosition = 22_050
    var framePosition: AVAudioFramePosition = 0
    init(_ source: PlaybackSource?) { playbackSource = source }
    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        let n = min(AVAudioFramePosition(frames), length - framePosition)
        buffer.frameLength = AVAudioFrameCount(max(0, n))
        framePosition += max(0, n)
    }
}

@MainActor
@Test("The source mark changes with the playing track, not when the next one is read ahead; local files have none")
func sourceMarkFollowsThePlayingTrack() async throws {
    let player = PlayerState(graph: WallClockGraph())
    let sources: [String: PlaybackSource?] = ["a": .transcode(.normal), "b": .offline, "c": nil]
    player.engine.sourceOpener = { track, _ in MarkedSource(sources[track.title] ?? nil) }
    let tracks = ["a", "b", "c"].map { Track(url: URL(fileURLWithPath: "/srv/\($0).flac"), title: $0, duration: 0.5, fileFormat: .flac) }
    player.startFreshQueue(tracks, startAt: 0)
    player.engine.play()

    func at(_ seconds: Double) async throws -> PlaybackSource? {
        let deadline = Date().addingTimeInterval(3)
        while player.currentTime < seconds || player.currentTrack == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return player.source
    }
    #expect(try await at(0.1) == .transcode(.normal))
    #expect(player.currentTrack?.title == "a", "b is already read ahead, but a is playing")
    func until(_ title: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while player.currentTrack?.title != title, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
    try await until("b")
    #expect(player.currentTrack?.title == "b")
    #expect(player.source == .offline, "switches with the track")
    try await until("c")
    #expect(player.currentTrack?.title == "c")
    #expect(player.source == nil)
    player.engine.pause()
}

// MARK: - Coming back from a server

/// `seconds` of 44.1k 16-bit stereo silence.
private func writeWAV(_ url: URL, seconds: Int) throws {
    let samples = 44_100 * 4 * seconds
    func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    var data = Data("RIFF".utf8) + le32(36 + samples) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2)
    data += le32(44100) + le32(44100 * 4) + le16(4) + le16(16) + Data("data".utf8) + le32(samples) + Data(count: samples)
    try data.write(to: url)
}

@MainActor
private func waitUntil(_ seconds: Double = 10, _ done: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor
@Test("Back from a server, this Mac's library shows at once; only new and edited files are read again")
func backFromAServer() async throws {
    // The real path: the temp folder is behind /var → /private/var, the scan
    // reports /private/var, and resolvingSymlinksInPath() strips /private.
    let made = try FixtureSupport.makeTempDir("switch-back")
    let dir = URL(fileURLWithPath: String(cString: realpath(made.path, nil)), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeWAV(dir.appendingPathComponent("a.wav"), seconds: 1)
    try writeWAV(dir.appendingPathComponent("b.wav"), seconds: 1)
    let sidecar = dir.appendingPathComponent(".flactastic/metadata-cache.json")

    let library = LibraryStore()
    library.openFolder(dir)
    await waitUntil { library.hasFinishedLaunchWork && FileManager.default.fileExists(atPath: sidecar.path) }
    try #require(library.tracks.count == 2)
    let ids = Set(library.tracks.map(\.id))

    library.openServer(root: dir.appendingPathComponent("server", isDirectory: true), tracks: [])
    #expect(library.tracks.isEmpty)
    // While away: one file added, one edited.
    try writeWAV(dir.appendingPathComponent("c.wav"), seconds: 1)
    try writeWAV(dir.appendingPathComponent("b.wav"), seconds: 3)

    library.openFolder(dir)
    #expect(library.tracks.count == 2, "shown at once, before any scan")
    #expect(Set(library.tracks.map(\.id)) == ids)
    #expect(!library.isLoadingFolder)

    await waitUntil { library.tracks.count == 3 && library.tracks.first { $0.title == "b" }?.duration.map { $0 > 2 } == true }
    #expect(library.tracks.count == 3, "the new file")
    #expect((library.tracks.first { $0.title == "b" }?.duration ?? 0) > 2, "the edited file, read again")
    #expect(ids.isSubset(of: Set(library.tracks.map(\.id))), "the others keep their IDs")
}
