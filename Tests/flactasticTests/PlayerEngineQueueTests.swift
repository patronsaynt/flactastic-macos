import AVFoundation
import Foundation
import Testing
@testable import flactastic

/// Fake graph with a manually advanced playback clock. Buffers' `.dataConsumed`
/// handlers fire once the clock passes their end, so the engine's throttle
/// behaves as with a real player node.
private final class ClockGraph: AudioGraphProtocol, @unchecked Sendable {
    let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let lock = NSLock()
    private var sampleTime: AVAudioFramePosition = 0
    private var scheduledEnd: AVAudioFramePosition = 0
    private var pending: [(AVAudioFramePosition, @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)] = []
    private(set) var flushCount = 0

    func prepare() throws {}
    func reprepare() {}
    func schedule(_ buffer: AVAudioPCMBuffer, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        lock.lock(); scheduledEnd += AVAudioFramePosition(buffer.frameLength)
        pending.append((scheduledEnd, completionHandler)); lock.unlock()
    }
    func play() {}
    func pause() {}
    func flush() {
        lock.lock(); sampleTime = 0; scheduledEnd = 0; pending = []; flushCount += 1; lock.unlock()
    }
    var isNodePlaying: Bool { true }
    func currentPlayerSampleTime() -> AVAudioFramePosition? { lock.lock(); defer { lock.unlock() }; return sampleTime }
    /// Advance playback, never past what's been scheduled. Returns the
    /// frames actually played.
    @discardableResult
    func advance(frames: AVAudioFramePosition) -> AVAudioFramePosition {
        lock.lock()
        let start = sampleTime
        sampleTime = min(sampleTime + frames, scheduledEnd)
        let done = pending.filter { $0.0 <= sampleTime }
        pending.removeAll { $0.0 <= sampleTime }
        let played = sampleTime - start
        lock.unlock()
        for (_, h) in done { h(.dataConsumed) }
        return played
    }
    func setOutputVolume(_ volume: Float) {}
    func onConfigurationChange(_ handler: @escaping @Sendable () -> Void) {}
    func applyOutput(_ config: AudioOutputConfig) throws {}
    var isInSyncWithDevice: Bool { true }
    func installAnalysisTap(bufferSize: AVAudioFrameCount,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    func removeAnalysisTap() {}
}

private func makeWAV(_ name: String, seconds: Double, rate: Double = 44_100) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flactastic-engine-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name)-\(Int(rate)).wav")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate))!
    buf.frameLength = buf.frameCapacity
    try file.write(from: buf)
    return url
}

@MainActor
private func track(_ name: String, _ seconds: Double, rate: Double = 44_100) throws -> Track {
    Track(url: try makeWAV(name, seconds: seconds, rate: rate), title: name, duration: seconds, fileFormat: .wav)
}

/// Plays `seconds` of audio, waiting for the decoder whenever the clock
/// catches up with what it has scheduled (it lags under load), so no time is
/// lost. Gives up after 2 s without progress: the queue has played out.
@MainActor
private func play(_ engine: PlayerEngine, _ graph: ClockGraph, seconds: Double) async {
    var left = AVAudioFramePosition(seconds * 44_100)
    var lastProgress = ContinuousClock.now
    while left > 0 {
        let played = graph.advance(frames: min(11_025, left))
        left -= played
        if played > 0 {
            lastProgress = .now
        } else if ContinuousClock.now - lastProgress > .seconds(2) {
            break
        }
        try? await Task.sleep(for: .milliseconds(15))
    }
    try? await Task.sleep(for: .milliseconds(120))
}

/// Waits up to 2 s for `condition`, for state the engine's 50 ms tick or
/// its decode task publishes a little late under load.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Adding to the queue while the last track's tail is already buffered
/// starts a decode pass at the new track. That pass must not overwrite the
/// playing track's duration — the seek bar is drawn as time / duration, so a
/// longer queued track made the thumb jump backward mid-song.
@MainActor
@Test func queueingAfterLastTrackFullyBufferedKeepsSeekBarDuration() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    engine.setQueue([try track("A", 60)], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    // Within the ~10 s look-ahead of the end: A is fully decoded, decoder idle.
    await play(engine, graph, seconds: 55)

    engine.appendTracks([try track("Long", 120)])
    try? await Task.sleep(for: .milliseconds(300))
    await play(engine, graph, seconds: 0.5)
    await waitUntil { abs(engine.currentTime - 55.5) < 0.1 }

    #expect(engine.currentTrack?.title == "A")
    #expect(engine.duration == 60)
    #expect(abs(engine.currentTime - 55.5) < 0.1)

    // Once playback crosses into the queued track, its duration takes over.
    await play(engine, graph, seconds: 10)
    await waitUntil { engine.currentTrack?.title == "Long" }
    #expect(engine.currentTrack?.title == "Long")
    #expect(engine.duration == 120)
    engine.pause()
}

/// Copies a fixture into its own folder so a test can move it like the
/// Organizer does without disturbing the shared fixture.
@MainActor
private func movableTrack(_ name: String, _ seconds: Double) throws -> Track {
    // Fixture names are cached by title, so key this one by its length too.
    let source = try track("\(name)-\(Int(seconds))s", seconds)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-relocate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("01 \(name).wav")
    try FileManager.default.copyItem(at: source.url, to: url)
    return Track(url: url, title: name, duration: seconds, fileFormat: .wav)
}

/// Organizer-style rename on disk; returns the old-path → new-URL map.
private func organize(_ tracks: [Track]) throws -> [String: URL] {
    var map: [String: URL] = [:]
    for t in tracks {
        let dest = t.url.deletingLastPathComponent().appendingPathComponent("01. Artist - \(t.title).wav")
        try FileManager.default.moveItem(at: t.url, to: dest)
        map[t.url.path] = dest
    }
    return map
}

/// The reported bug: files reorganized mid-album. The decoder reaches the
/// next tracks at their old paths, fails, and goes idle — playback stopped
/// at the end of the current song. Relocating must resume it.
@MainActor
@Test func organizingMidPlaybackResumesAfterDecoderGaveUp() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try movableTrack("A", 20), b = try movableTrack("B", 20), c = try movableTrack("C", 20)
    engine.setQueue([a, b, c], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))

    let moves = try organize([a, b, c])
    // Into A's last 10 s: the decoder has tried B and C at their old paths.
    await play(engine, graph, seconds: 15)
    try? await Task.sleep(for: .milliseconds(300))

    engine.relocate(moves)
    try? await Task.sleep(for: .milliseconds(300))
    await play(engine, graph, seconds: 10)

    #expect(engine.currentTrack?.title == "B")
    #expect(engine.currentTrack?.url == moves[b.url.path])
    #expect(engine.queue.map(\.url) == [a, b, c].map { moves[$0.url.path] })
    await play(engine, graph, seconds: 20)
    #expect(engine.currentTrack?.title == "C")
    engine.pause()
}

/// Relocated before the decoder gets there: it simply opens the new paths.
@MainActor
@Test func organizingMidPlaybackBeforeNextTrackKeepsGoing() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try movableTrack("A", 30), b = try movableTrack("B", 20)
    engine.setQueue([a, b], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 5)

    engine.relocate(try organize([a, b]))
    await play(engine, graph, seconds: 30)
    #expect(engine.currentTrack?.title == "B")
    engine.pause()
}

/// Background tag writes wait for the file to stop playing: the playing
/// track (through scrubbing and pausing), and the next one once its audio is
/// read ahead for the gapless join. A track that finished, or was skipped,
/// is free; so is everything once the queue has played out.
@MainActor
@Test func filesInUseCoverPlayingAndReadAheadTracksOnly() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("UseA", 30), b = try track("UseB", 30), c = try track("UseC", 30)
    func inUse(_ t: Track) -> Bool { engine.filesInUse.contains(t.url.standardizedFileURL.path) }
    engine.setQueue([a, b, c], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(inUse(a) && !inUse(b))

    // A write for the playing track is held, through a scrub and a pause.
    let guardian = PlaybackFileGuard.shared
    guardian.filesInUse = { engine.filesInUse }
    var wroteA = false
    guardian.whenFree(a.url) { wroteA = true }
    engine.seek(to: 12)
    engine.pause()
    try? await Task.sleep(for: .milliseconds(150))
    guardian.release()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!wroteA)
    #expect(inUse(a))
    engine.play()

    // Near A's end, B is read ahead for the gapless join: in use too.
    await play(engine, graph, seconds: 15)
    #expect(inUse(a) && inUse(b))

    // Across the join A is done: its held write runs; B's waits.
    var wroteB = false
    guardian.whenFree(b.url) { wroteB = true }
    await play(engine, graph, seconds: 5)
    await waitUntil { engine.currentTrack?.title == "UseB" }
    #expect(engine.currentTrack?.title == "UseB")
    guardian.release()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(wroteA)
    #expect(!wroteB)

    // Skipping frees the skipped track.
    engine.next()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(!inUse(b) && inUse(c))
    guardian.release()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(wroteB)

    // Played to the end: nothing is in use.
    await play(engine, graph, seconds: 31)
    #expect(engine.filesInUse.isEmpty)
    guardian.filesInUse = { [] }
}
