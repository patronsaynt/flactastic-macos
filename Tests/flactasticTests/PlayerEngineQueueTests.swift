import AVFoundation
import Foundation
import os
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
    private(set) var pauseCount = 0

    func prepare() throws {}
    func reprepare() {}
    func schedule(_ buffer: AVAudioPCMBuffer, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                  completionHandler: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        lock.lock(); scheduledEnd += AVAudioFramePosition(buffer.frameLength)
        pending.append((scheduledEnd, completionHandler)); lock.unlock()
    }
    func play() {}
    func pause() { lock.lock(); pauseCount += 1; lock.unlock() }
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

/// Dragging upcoming tracks around while the playing one is still being read
/// must leave its audio alone: no restart, no flush, and no hold. The hold
/// was the audible stutter — a replaced decode pass zeroed the throttle's
/// count while ~10 s still sat in the node, so the starvation check paused
/// output until the new pass reopened the track (a network round trip for a
/// stream). The opener here is slow, like a stream.
@MainActor
@Test func reorderingUpcomingTracksDoesNotInterruptPlayback() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("DragA", 60), b = try track("DragB", 20), c = try track("DragC", 20)
    engine.setQueue([a, b, c], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 5)

    let opens = OSAllocatedUnfairLock(initialState: 0)
    engine.sourceOpener = { _, _ in
        opens.withLock { $0 += 1 }
        try await Task.sleep(for: .milliseconds(600))
        return nil
    }
    let pausesBefore = graph.pauseCount
    engine.reorderQueue([a, c, b], currentIndex: 0)
    try? await Task.sleep(for: .milliseconds(300))

    #expect(!engine.isHolding)
    #expect(graph.pauseCount == pausesBefore)
    #expect(graph.flushCount == 1) // the initial setQueue only
    #expect(opens.withLock { $0 } == 0) // A was never reopened

    // The new order plays: C follows A.
    await play(engine, graph, seconds: 56)
    await waitUntil { engine.currentTrack?.title == "DragC" }
    #expect(engine.currentTrack?.title == "DragC")
    engine.pause()
}

/// A reorder that moves the playing track's index (shuffle, or a played
/// track dragged after it) used to restart the decoder and reopen the
/// stream mid-song. The decoder now follows the track it's reading by ID,
/// so nothing restarts: no reopen, no hold, nothing skipped or repeated.
@MainActor
@Test func reorderThatMovesTheCurrentIndexDoesNotRestartDecode() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("ShufA", 60), b = try track("ShufB", 20), c = try track("ShufC", 20)
    engine.setQueue([a, b, c], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 5)

    let opens = OSAllocatedUnfairLock(initialState: 0)
    engine.sourceOpener = { _, _ in
        opens.withLock { $0 += 1 }
        return nil
    }
    let pausesBefore = graph.pauseCount
    engine.reorderQueue([b, a, c], currentIndex: 1)
    await play(engine, graph, seconds: 1)

    #expect(!engine.isHolding)
    #expect(graph.pauseCount == pausesBefore)
    #expect(graph.flushCount == 1)
    #expect(opens.withLock { $0 } == 0)
    await waitUntil { abs(engine.currentTime - 6) < 0.1 }
    #expect(abs(engine.currentTime - 6) < 0.1)

    // A plays to its full length, then C (B is now behind it).
    await play(engine, graph, seconds: 53.5)
    #expect(engine.currentTrack?.title == "ShufA")
    await play(engine, graph, seconds: 1)
    await waitUntil { engine.currentTrack?.title == "ShufC" }
    #expect(engine.currentTrack?.title == "ShufC")
    engine.pause()
}

/// Near a track's end the next one is already loaded. Edits further down
/// the queue leave it alone (no flush); moving the loaded track itself has
/// to rebuild, and the new order then plays.
@MainActor
@Test func editsNearTheEndOnlyFlushWhenTheyMoveLoadedAudio() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("EndA", 30), b = try track("EndB", 20), c = try track("EndC", 20), d = try track("EndD", 20)
    engine.setQueue([a, b, c, d], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 25) // B is read ahead now

    engine.reorderQueue([a, b, d, c], currentIndex: 0)
    engine.removeFromQueue(at: 3)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(graph.flushCount == 1)

    engine.reorderQueue([a, d, b], currentIndex: 0)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(graph.flushCount == 2)
    await waitUntil { abs(engine.currentTime - 25) < 0.2 }
    #expect(engine.currentTrack?.title == "EndA")

    await play(engine, graph, seconds: 6)
    await waitUntil { engine.currentTrack?.title == "EndD" }
    #expect(engine.currentTrack?.title == "EndD")
    engine.pause()
}

/// Inserting at or before the playing track shifts its index. The decoder
/// follows tracks by ID, so it still moves on to the right one.
@MainActor
@Test func insertingBeforeTheCurrentTrackKeepsTheNextOneRight() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("InsA", 30), b = try track("InsB", 20), x = try track("InsX", 20)
    engine.setQueue([a, b], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 5)

    engine.insertTracks([x], at: 0)
    #expect(engine.currentIndex == 1)
    #expect(graph.flushCount == 1)
    await play(engine, graph, seconds: 26)
    await waitUntil { engine.currentTrack?.title == "InsB" }
    #expect(engine.currentTrack?.title == "InsB")
    engine.pause()
}

/// A track whose reads take only what `budget` allows, waiting otherwise —
/// a stream whose link can be throttled from the test.
private final class MeteredSource: PCMSource, @unchecked Sendable {
    let file: AVAudioFile
    let budget = OSAllocatedUnfairLock<Int64>(initialState: .max)
    init(_ url: URL) throws { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
    var processingFormat: AVAudioFormat { file.processingFormat }
    var length: AVAudioFramePosition { file.length }
    var framePosition: AVAudioFramePosition {
        get { file.framePosition }
        set { file.framePosition = newValue }
    }
    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        var n: Int64 = 0
        while n == 0 {
            n = budget.withLock { b in let take = min(b, Int64(frames)); b -= take; return take }
            if n == 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
    }
}

/// Running dry mid-song holds output until a few seconds are queued again,
/// not the half second a start needs — on a slow link, resuming at once
/// just runs dry again (a stutter loop).
@MainActor
@Test func afterRunningDryPlaybackWaitsForSecondsNotAFraction() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("DryA", 60)
    let source = try MeteredSource(a.url)
    engine.sourceOpener = { _, _ in source }
    engine.setQueue([a], startAt: 0)
    engine.play()
    // Started and well stocked (slow under a loaded test run, so wait for it).
    await waitUntil { !engine.isHolding && engine.currentTime >= 0 }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(!engine.isHolding)

    source.budget.withLock { $0 = 0 }
    await play(engine, graph, seconds: 12)
    await waitUntil { engine.isHolding }
    #expect(engine.isHolding)

    // Two seconds arrive: enough to start, not enough after running dry.
    source.budget.withLock { $0 = 2 * 44_100 }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(engine.isHolding)

    source.budget.withLock { $0 = 3 * 44_100 }
    await waitUntil { !engine.isHolding }
    #expect(!engine.isHolding)

    // A seek starts quickly again: half a second will do.
    source.budget.withLock { $0 = 0 }
    engine.seek(to: 30)
    source.budget.withLock { $0 = 44_100 }
    await waitUntil { !engine.isHolding }
    #expect(!engine.isHolding)
    source.budget.withLock { $0 = .max }
    engine.pause()
}

/// Offline copies and streamed tracks in one queue, with the server away:
/// the streamed one is skipped at once and the next offline copy follows
/// straight on.
@MainActor
@Test func mixedQueueSkipsStreamedTracksWhileTheServerIsAway() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("MixA", 20), c = try track("MixC", 20)
    let b = Track(url: URL(fileURLWithPath: "/nonexistent/flactastic/MixB.flac"), title: "MixB", duration: 20, fileFormat: .flac)
    func info(_ t: Track) -> ServerStreamer.TrackInfo {
        ServerStreamer.TrackInfo(id: UUID(), format: .wav, fileSize: 1000, contentHash: nil,
                                 sampleRate: 44_100, bitrate: 1411, frames: nil, duration: 20)
    }
    let (ia, ib, ic) = (info(a), info(b), info(c))
    let streamer = ServerStreamer()
    streamer.config.withLock {
        $0 = .init(client: ServerClient(address: ServerAddress(host: "away.invalid"), pin: nil, token: "t"),
                   quality: .original, transcoding: false,
                   tracks: [a.url.standardizedFileURL.path: ia, b.url.standardizedFileURL.path: ib, c.url.standardizedFileURL.path: ic],
                   offline: [ia.id, ic.id], reachable: false)
    }
    engine.sourceOpener = { track, seconds in try await streamer.open(track, at: seconds) }
    engine.setQueue([a, b, c], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 21)
    await waitUntil { engine.currentTrack?.title == "MixC" }
    #expect(engine.currentTrack?.title == "MixC")
    #expect(abs(engine.currentTime - 1) < 0.2, "C follows A straight on")
    engine.pause()
}

/// Automatic quality hears about a struggling stream from the engine's
/// buffer: once, when it falls from healthy (5 s) below 2 s while playing —
/// not while it's still filling at the start, and not again until it has
/// recovered.
@MainActor
@Test func lowBufferIsReportedOnceAfterBeingHealthy() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("LowA", 60)
    let source = try MeteredSource(a.url)
    source.budget.withLock { $0 = 3 * 44_100 }
    engine.sourceOpener = { _, _ in source }
    var reports = 0
    engine.stalled = { reports += 1 }
    engine.setQueue([a], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(300))
    #expect(reports == 0, "3 s queued at the start: still filling")

    source.budget.withLock { $0 = .max }
    try? await Task.sleep(for: .milliseconds(300)) // ~10 s queued: healthy
    source.budget.withLock { $0 = 0 }
    await play(engine, graph, seconds: 8.6)
    await waitUntil { reports == 1 }
    #expect(reports == 1)
    #expect(!engine.isHolding, "told before running dry")
    await play(engine, graph, seconds: 0.5)
    #expect(reports == 1, "once per dip")
    source.budget.withLock { $0 = .max }
    engine.pause()
}

/// A playlist can list the same song twice, both copies under one ID. After
/// the second copy the decoder must go on to what follows *it*, not loop
/// back to what follows the first.
@MainActor
@Test func aSongListedTwicePlaysOnAfterItsSecondCopy() async throws {
    let graph = ClockGraph()
    let engine = PlayerEngine(graph: graph)
    let a = try track("TwiceA", 5), b = try track("TwiceB", 5), c = try track("TwiceC", 5)
    engine.setQueue([a, b, a, c], startAt: 0)
    engine.play()
    try? await Task.sleep(for: .milliseconds(200))
    await play(engine, graph, seconds: 12)
    await waitUntil { engine.currentIndex == 2 }
    #expect(engine.currentIndex == 2)
    await play(engine, graph, seconds: 4)
    await waitUntil { engine.currentTrack?.title == "TwiceC" }
    #expect(engine.currentTrack?.title == "TwiceC")
    #expect(engine.currentIndex == 3)
    engine.pause()
}
