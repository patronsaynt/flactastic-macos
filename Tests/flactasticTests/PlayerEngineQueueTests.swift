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
    /// Advance playback, never past what's been scheduled.
    func advance(seconds: Double) {
        lock.lock()
        sampleTime = min(sampleTime + AVAudioFramePosition(seconds * 44_100), scheduledEnd)
        let done = pending.filter { $0.0 <= sampleTime }
        pending.removeAll { $0.0 <= sampleTime }
        lock.unlock()
        for (_, h) in done { h(.dataConsumed) }
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

@MainActor
private func play(_ engine: PlayerEngine, _ graph: ClockGraph, seconds: Double) async {
    var left = seconds
    while left > 0 {
        let step = min(0.25, left)
        graph.advance(seconds: step)
        left -= step
        try? await Task.sleep(for: .milliseconds(15))
    }
    try? await Task.sleep(for: .milliseconds(120))
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

    #expect(engine.currentTrack?.title == "A")
    #expect(engine.duration == 60)
    #expect(abs(engine.currentTime - 55.5) < 0.1)

    // Once playback crosses into the queued track, its duration takes over.
    await play(engine, graph, seconds: 10)
    #expect(engine.currentTrack?.title == "Long")
    #expect(engine.duration == 120)
    engine.pause()
}
