@preconcurrency import AVFoundation
import os

/// The gapless audio engine. Lives on `@MainActor` so transport methods can be called
/// synchronously from SwiftUI. Heavy decode work is dispatched off the main actor.
@MainActor
final class PlayerEngine {

    // MARK: - Public state (read from PlayerState)

    private(set) var currentTrack: Track?
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var volume: Float = 0.75

    var queue: [Track] { _queue }
    var currentIndex: Int { _currentIndex }

    // MARK: - State update callback

    var onStateUpdate: (@MainActor () -> Void)?

    // MARK: - Private

    private let graph: any AudioGraphProtocol
    private var _queue: [Track] = []
    private var _currentIndex: Int = 0
    private var scheduledEntries: [ScheduledEntry] = []
    private var nextScheduleFrame: AVAudioFramePosition = 0
    private var decodeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var isPrepared = false
    private var isDecoding = false
    private var seekTimeOffset: TimeInterval = 0

    /// Tracks which scheduled entry playback is currently inside (by its startFrame).
    /// Used to detect entry transitions — including loops of the same track under
    /// repeat-one — so we can reset seekTimeOffset at boundaries.
    private var currentEntryStartFrame: AVAudioFramePosition = -1

    /// When true, the decode task re-schedules the current track indefinitely
    /// instead of advancing to the next.
    var isRepeatOne: Bool = false {
        didSet {
            guard oldValue != isRepeatOne, !_queue.isEmpty, isPrepared else { return }
            if isRepeatOne {
                // Only flush if a different track has already been pre-scheduled.
                // With the throttle capped at ~10 s, this only happens for short tracks
                // or when the user toggles repeat right at the end of one. For typical
                // music tracks (> 10 s) the decode task is still on the current track,
                // so we can just let it pick up isRepeatOne naturally — no cut.
                let nextTrackScheduled = scheduledEntries.contains(where: {
                    $0.track.id != currentTrack?.id
                })
                if nextTrackScheduled {
                    rebuildDecodePipeline()
                }
            }
            // Turning OFF: no flush — the decode task advances to the next track
            // on its own after the current loop iteration finishes.
        }
    }

    /// Generation counter — incremented on every cancel to invalidate stale decode tasks.
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Tracks the end of the most recently *scheduled* canonical frame, updated
    /// continuously by the decode task after each buffer is handed to the player node.
    /// Read by reorderQueue() to know exactly where new decode should start, without
    /// flushing already-playing audio.
    private let liveScheduleEnd = OSAllocatedUnfairLock(initialState: AVAudioFramePosition(0))

    /// Backpressure: caps how many canonical frames are scheduled but not yet consumed.
    private let throttle = BufferThrottle()

    /// Output chunk: ~0.37s at 44.1 kHz. Small enough for responsive seek, large enough to avoid overhead.
    private let outputChunkFrames: AVAudioFrameCount = 16_384

    /// Read chunk for converter input block (source frames).
    private let readChunkFrames: AVAudioFrameCount = 8_192

    private struct ScheduledEntry {
        let track: Track
        let startFrame: AVAudioFramePosition
        var endFrame: AVAudioFramePosition
    }

    // MARK: - Init

    init(graph: (any AudioGraphProtocol)? = nil) {
        self.graph = graph ?? AppleAudioGraph()
    }

    private func ensurePrepared() {
        guard !isPrepared else { return }
        do {
            try graph.prepare()
            // Set throttle limit based on actual device sample rate (~10 seconds of audio).
            let rate = graph.canonicalFormat.sampleRate
            throttle.setLimit(Int64(rate * 10))

            graph.onConfigurationChange { [weak self] in
                Task { @MainActor in
                    self?.handleConfigurationChange()
                }
            }
            isPrepared = true
        } catch {
            print("[PlayerEngine] Failed to prepare audio graph: \(error)")
        }
    }

    // MARK: - Transport API

    func setQueue(_ tracks: [Track], startAt index: Int) {
        ensurePrepared()
        cancelDecode()
        graph.flush()
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        seekTimeOffset = 0
        currentEntryStartFrame = -1

        _queue = tracks
        _currentIndex = min(index, max(tracks.count - 1, 0))
        if _queue.isEmpty {
            currentTrack = nil
            duration = nil
            currentTime = 0
            isPlaying = false
            notifyStateUpdate()
            return
        }

        currentTrack = _queue[_currentIndex]
        duration = currentTrack?.duration
        currentTime = 0
        notifyStateUpdate()

        startDecoding(from: _currentIndex)
    }

    func play() {
        ensurePrepared()
        graph.play()
        isPlaying = true
        startTick()
        notifyStateUpdate()
    }

    func pause() {
        graph.pause()
        isPlaying = false
        stopTick()
        notifyStateUpdate()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !_queue.isEmpty else { return }
        let nextIndex = _currentIndex + 1
        if nextIndex < _queue.count {
            setQueue(_queue, startAt: nextIndex)
            play()
        }
    }

    /// Append tracks to the end of the queue without disturbing currently-playing audio.
    /// If the queue was empty, this starts playback from the first appended track.
    /// If the decode task is idle (caught up), a new decode pass is started for the new tracks.
    /// If decode is still running, it will pick up the new tracks on its next iteration.
    func appendTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        ensurePrepared()
        let wasEmpty = _queue.isEmpty
        let resumeIndex = _queue.count
        _queue.append(contentsOf: tracks)

        if wasEmpty {
            _currentIndex = 0
            currentTrack = _queue[0]
            duration = currentTrack?.duration
            currentTime = 0
            seekTimeOffset = 0
            notifyStateUpdate()
            startDecoding(from: 0)
            return
        }

        // Non-empty: if decoder is idle, kick it off from the first new track.
        if !isDecoding {
            startDecoding(from: resumeIndex)
        }
        notifyStateUpdate()
    }

    /// Insert tracks into the queue at the given index without interrupting playback
    /// when possible. If the decode task hasn't pre-buffered any future track yet,
    /// the inserted tracks are picked up on the next decode iteration and no flush
    /// is needed. Falls back to a full pipeline rebuild only when a future track has
    /// already been loaded into the player node and would be played out of order.
    func insertTracks(_ tracks: [Track], at index: Int) {
        guard !tracks.isEmpty else { return }
        ensurePrepared()

        if _queue.isEmpty {
            setQueue(tracks, startAt: 0)
            return
        }

        let clampedIndex = min(max(index, 0), _queue.count)
        _queue.insert(contentsOf: tracks, at: clampedIndex)
        // If insertion is at or before the current track, current index shifts.
        if clampedIndex <= _currentIndex {
            _currentIndex += tracks.count
        }

        // If no future track has been pre-buffered yet, the running decode task will
        // encounter the inserted tracks naturally on its next queue read — no flush needed.
        let nextTrackAlreadyScheduled = scheduledEntries.contains(where: {
            $0.track.id != currentTrack?.id
        })

        if !nextTrackAlreadyScheduled {
            // If the decoder went idle before we inserted (e.g. single-track queue),
            // kick it off from the next position so new tracks get decoded.
            if !isDecoding {
                let nextIdx = _currentIndex + 1
                if nextIdx < _queue.count {
                    startDecoding(from: nextIdx)
                }
            }
            notifyStateUpdate()
            return
        }

        // A pre-buffered future track would be displaced — flush and rebuild.
        let wasPlaying = isPlaying
        let savedTime = currentTime
        cancelDecode()
        graph.flush()
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        currentEntryStartFrame = -1
        seekTimeOffset = savedTime
        currentTime = savedTime
        currentTrack = _queue[_currentIndex]
        duration = currentTrack?.duration
        notifyStateUpdate()

        startDecoding(from: _currentIndex, seekOffset: savedTime)
        if wasPlaying { play() }
    }

    /// Remove a single upcoming track from the queue without interrupting playback
    /// when possible. If the removed track and no other future track has been
    /// pre-buffered, the decode task is cancelled and restarted from the current
    /// continuation point — identical to `reorderQueue`'s seamless path. Falls back
    /// to a full flush only when the removed track's audio is already in the player node.
    func removeFromQueue(at index: Int) {
        guard index > _currentIndex, index < _queue.count else { return }

        let removedTrack = _queue[index]
        let alreadyScheduled = scheduledEntries.contains(where: { $0.track.id == removedTrack.id })
        let nextTrackAlreadyScheduled = scheduledEntries.contains(where: { $0.track.id != currentTrack?.id })

        _queue.remove(at: index)

        // Common case: decoder is still on the current track and the removed track's
        // audio hasn't been loaded. Cancel and restart from the current continuation
        // point — no flush, so the playing audio is uninterrupted.
        if !alreadyScheduled && !nextTrackAlreadyScheduled && !scheduledEntries.isEmpty {
            let endFrame = liveScheduleEnd.withLock { $0 }
            let canonicalRate = graph.canonicalFormat.sampleRate
            let currentEntryStart = scheduledEntries.last?.startFrame ?? 0
            let preScheduledSeconds = Double(endFrame - currentEntryStart) / canonicalRate
            let continuationOffset = seekTimeOffset + preScheduledSeconds

            cancelDecode()
            nextScheduleFrame = endFrame
            notifyStateUpdate()
            startDecoding(from: _currentIndex, seekOffset: continuationOffset, appendingEntry: !scheduledEntries.isEmpty)
            return
        }

        // Fallback: the removed track's audio is in the player node (or another future
        // track is already buffered) — flush and rebuild to restore correct order.
        let wasPlaying = isPlaying
        let savedTime = currentTime
        cancelDecode()
        graph.flush()
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        currentEntryStartFrame = -1
        seekTimeOffset = savedTime
        currentTime = savedTime
        currentTrack = _queue[_currentIndex]
        duration = currentTrack?.duration
        notifyStateUpdate()

        startDecoding(from: _currentIndex, seekOffset: savedTime)
        if wasPlaying { play() }
    }

    func previous() {
        guard !_queue.isEmpty else { return }
        if currentTime > 3 {
            setQueue(_queue, startAt: _currentIndex)
            play()
        } else {
            let prevIndex = max(_currentIndex - 1, 0)
            setQueue(_queue, startAt: prevIndex)
            play()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard !_queue.isEmpty else { return }
        let wasPlaying = isPlaying
        cancelDecode()
        graph.flush()
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        currentEntryStartFrame = -1

        let clamped = max(0, seconds)
        seekTimeOffset = clamped
        currentTime = clamped
        notifyStateUpdate()

        startDecoding(from: _currentIndex, seekOffset: clamped)
        if wasPlaying { play() }
    }

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        graph.setOutputVolume(volume)
        notifyStateUpdate()
    }

    func volumeUp() { setVolume(volume + 0.05) }
    func volumeDown() { setVolume(volume - 0.05) }

    // MARK: - Analysis tap (visualizer)

    func installAnalysisTap(bufferSize: AVAudioFrameCount = 1024,
                            _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        graph.installAnalysisTap(bufferSize: bufferSize, block)
    }

    func removeAnalysisTap() {
        graph.removeAnalysisTap()
    }

    // MARK: - Decode pipeline

    /// Flush all scheduled audio and restart decoding from the current track at
    /// its current playback time. Used when `isRepeatOne` toggles — any pre-decoded
    /// "next track" audio needs to be discarded so the current track loops instead.
    private func rebuildDecodePipeline() {
        let wasPlaying = isPlaying
        let savedTime = currentTime
        cancelDecode()
        graph.flush()
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        currentEntryStartFrame = -1
        seekTimeOffset = savedTime
        currentTime = savedTime
        notifyStateUpdate()
        startDecoding(from: _currentIndex, seekOffset: savedTime)
        if wasPlaying { play() }
    }

    /// Rearrange the queue (e.g. for shuffle/unshuffle) without flushing the audio
    /// pipeline. The currently-playing audio — and the rest of the current track —
    /// continue uninterrupted. Decode is cancelled and restarted from the *current*
    /// track's continuation point so it plays to completion before moving to the new
    /// next track. Falls back to a full rebuild only when a different track has already
    /// been pre-scheduled (current track has < ~10 s remaining).
    func reorderQueue(_ tracks: [Track], currentIndex: Int) {
        guard !tracks.isEmpty else { return }
        _queue = tracks
        _currentIndex = currentIndex

        // Check whether a track other than the current one has already been decoded
        // into the player node's buffer queue.
        let nextTrackAlreadyScheduled = scheduledEntries.contains(where: {
            $0.track.id != currentTrack?.id
        })

        if nextTrackAlreadyScheduled {
            // Rare edge case (current track < 10 s remaining when shuffle fired).
            // Fall back to a full rebuild — unavoidable brief cut.
            rebuildDecodePipeline()
            return
        }

        // Snapshot where the pre-scheduled audio ends (≈ the throttle look-ahead,
        // typically ~10 s worth of frames). We will continue decoding the current
        // track from this point so it plays fully before the shuffled next track.
        let endFrame = liveScheduleEnd.withLock { $0 }

        // How far into the current track's source file should the continuation seek?
        // That's: time already played (seekTimeOffset) + the pre-buffered window.
        let currentEntryStart = scheduledEntries.last?.startFrame ?? 0
        let canonicalRate = graph.canonicalFormat.sampleRate
        let preScheduledSeconds = Double(endFrame - currentEntryStart) / canonicalRate
        let continuationOffset = seekTimeOffset + preScheduledSeconds

        cancelDecode()

        // Tell the new decode task where in the player-node frame timeline to start
        // appending buffers.
        nextScheduleFrame = endFrame

        // Intentionally leave scheduledEntries alone — the current track's entry
        // (endFrame == .max) stays. The continuation decode will finalize it when
        // the track is fully scheduled, giving updateTime() a correct boundary.

        notifyStateUpdate()

        // Restart decode from the current track at the continuation file offset.
        // appendingEntry:true means it will NOT create a new ScheduledEntry for the
        // first (current) track — it appends to the existing one. When the track
        // finishes, the task naturally advances to _queue[currentIndex + 1], which
        // is now the shuffled next track.
        startDecoding(from: currentIndex, seekOffset: continuationOffset, appendingEntry: !scheduledEntries.isEmpty)
    }

    private func cancelDecode() {
        decodeTask?.cancel()
        decodeTask = nil
        generation.withLock { $0 &+= 1 }
        throttle.reset()
        isDecoding = false
    }

    private func startDecoding(from index: Int, seekOffset: TimeInterval = 0, appendingEntry: Bool = false) {
        let canonical = graph.canonicalFormat
        let readChunk = readChunkFrames
        let outputChunk = outputChunkFrames
        let graphRef = graph
        let throttle = self.throttle
        let myGeneration = generation.withLock { $0 }
        let generation = self.generation
        let scheduleEnd = self.liveScheduleEnd  // captured by reference (struct wraps OS pointer)

        isDecoding = true

        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            var trackIndex = index
            var isFirstTrack = true

            while !Task.isCancelled {
                // Read the current queue entry live on each iteration so appended
                // tracks are picked up without restarting the decode task.
                // Also atomically clear isDecoding when the queue is exhausted so
                // appendTracks() on the main actor can reliably detect idle.
                let nextTrack: Track? = await MainActor.run { [weak self] () -> Track? in
                    guard let self else { return nil }
                    if trackIndex >= self._queue.count {
                        self.isDecoding = false
                        return nil
                    }
                    return self._queue[trackIndex]
                }
                guard let track = nextTrack else { return }

                do {
                    let file = try AVAudioFile(
                        forReading: track.url,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                    let sourceFormat = file.processingFormat

                    // Seek within the first track.
                    if isFirstTrack && seekOffset > 0 {
                        let seekFrame = AVAudioFramePosition(seekOffset * sourceFormat.sampleRate)
                        file.framePosition = max(0, min(seekFrame, file.length - 1))
                    }

                    // Update duration for the current track.
                    let fileDuration = Double(file.length) / sourceFormat.sampleRate
                    if isFirstTrack {
                        await MainActor.run { [weak self] in
                            self?.duration = fileDuration
                        }
                    }

                    // Check if we can do a zero-conversion passthrough.
                    let needsConverter = sourceFormat.sampleRate != canonical.sampleRate
                        || sourceFormat.channelCount != canonical.channelCount

                    // Create converter only if needed.
                    var converter: AVAudioConverter?
                    if needsConverter {
                        guard let conv = AVAudioConverter(from: sourceFormat, to: canonical) else {
                            print("[PlayerEngine] Cannot create converter for \(track.title)")
                            trackIndex += 1
                            isFirstTrack = false
                            continue
                        }
                        conv.sampleRateConverterQuality = .max
                        converter = conv
                    }

                    // Create entry eagerly so updateTime() can track this track immediately.
                    // endFrame = .max is a sentinel meaning "still decoding".
                    //
                    // appendingEntry + isFirstTrack: this is a continuation decode that
                    // follows a reorderQueue() call. The existing ScheduledEntry for the
                    // current track (endFrame == .max) stays in place — we must NOT create
                    // a second entry. We only capture nextScheduleFrame so the finalization
                    // below can compute the correct absolute endFrame for the existing entry.
                    let startFrame = await MainActor.run { [weak self] () -> AVAudioFramePosition in
                        guard let self else { return 0 }
                        let sf = self.nextScheduleFrame
                        if appendingEntry && isFirstTrack {
                            // Continuation: no new entry. Just update the live pointer.
                            scheduleEnd.withLock { $0 = sf }
                        } else {
                            let entry = ScheduledEntry(track: track, startFrame: sf, endFrame: .max)
                            self.scheduledEntries.append(entry)
                            scheduleEnd.withLock { $0 = sf }
                        }
                        return sf
                    }

                    var totalScheduledFrames: AVAudioFramePosition = 0

                    if needsConverter, let converter {
                        // --- Converter path: pull-based conversion ---
                        let fileBox = UncheckedSendableBox(file)
                        var fileExhausted = false

                        while !fileExhausted, !Task.isCancelled {
                            if generation.withLock({ $0 }) != myGeneration { return }

                            guard let destBuffer = AVAudioPCMBuffer(
                                pcmFormat: canonical, frameCapacity: outputChunk
                            ) else { break }

                            var convError: NSError?
                            let srcFmt = sourceFormat
                            let chunkSize = readChunk

                            let status = converter.convert(to: destBuffer, error: &convError) { _, outStatus in
                                let f = fileBox.value
                                let remaining = AVAudioFrameCount(f.length - f.framePosition)
                                if remaining == 0 {
                                    outStatus.pointee = .endOfStream
                                    return nil
                                }
                                let toRead = min(chunkSize, remaining)
                                guard let srcBuf = AVAudioPCMBuffer(
                                    pcmFormat: srcFmt, frameCapacity: toRead
                                ) else {
                                    outStatus.pointee = .endOfStream
                                    return nil
                                }
                                do {
                                    try f.read(into: srcBuf, frameCount: toRead)
                                } catch {
                                    outStatus.pointee = .endOfStream
                                    return nil
                                }
                                if srcBuf.frameLength == 0 {
                                    outStatus.pointee = .endOfStream
                                    return nil
                                }
                                outStatus.pointee = .haveData
                                return srcBuf
                            }

                            if destBuffer.frameLength > 0 {
                                let frameCount = Int64(destBuffer.frameLength)

                                await throttle.acquire(frames: frameCount)
                                if generation.withLock({ $0 }) != myGeneration { return }

                                totalScheduledFrames += AVAudioFramePosition(frameCount)
                                graphRef.schedule(destBuffer, completionCallbackType: .dataConsumed) { _ in
                                    if generation.withLock({ $0 }) == myGeneration {
                                        throttle.release(frames: frameCount)
                                    }
                                }
                                // Keep live pointer current so reorderQueue() always knows
                                // the exact end of scheduled audio without needing a flush.
                                let liveEnd = startFrame + totalScheduledFrames
                                scheduleEnd.withLock { $0 = liveEnd }
                            }

                            if status == .endOfStream || status == .error {
                                if status == .error, let convError {
                                    print("[PlayerEngine] Converter error for \(track.title): \(convError)")
                                }
                                fileExhausted = true
                            }
                        }
                    } else {
                        // --- Passthrough path: read directly into schedule buffers ---
                        while file.framePosition < file.length, !Task.isCancelled {
                            if generation.withLock({ $0 }) != myGeneration { return }

                            let remaining = AVAudioFrameCount(file.length - file.framePosition)
                            let toRead = min(outputChunk, remaining)

                            guard let destBuffer = AVAudioPCMBuffer(
                                pcmFormat: canonical, frameCapacity: toRead
                            ) else { break }

                            try file.read(into: destBuffer, frameCount: toRead)
                            if destBuffer.frameLength == 0 { break }

                            let frameCount = Int64(destBuffer.frameLength)

                            await throttle.acquire(frames: frameCount)
                            if generation.withLock({ $0 }) != myGeneration { return }

                            totalScheduledFrames += AVAudioFramePosition(frameCount)
                            graphRef.schedule(destBuffer, completionCallbackType: .dataConsumed) { _ in
                                if generation.withLock({ $0 }) == myGeneration {
                                    throttle.release(frames: frameCount)
                                }
                            }
                            // Keep live pointer current (same reason as converter path above).
                            let liveEnd = startFrame + totalScheduledFrames
                            scheduleEnd.withLock { $0 = liveEnd }
                        }
                    }

                    // Finalize entry: replace .max sentinel with actual endFrame.
                    if generation.withLock({ $0 }) != myGeneration { return }
                    let actualEnd = startFrame + totalScheduledFrames
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if appendingEntry && isFirstTrack {
                            // Continuation mode: the existing entry was never given a new
                            // startFrame — find it by track identity + .max sentinel.
                            // actualEnd = liveScheduleEnd + continuationFrames, which is the
                            // correct absolute endFrame for the full track in the player node.
                            if let idx = self.scheduledEntries.firstIndex(where: {
                                $0.track.id == track.id && $0.endFrame == .max
                            }) {
                                self.scheduledEntries[idx].endFrame = actualEnd
                            }
                        } else {
                            // Normal mode: look up by the startFrame captured at entry creation.
                            if let idx = self.scheduledEntries.firstIndex(where: {
                                $0.startFrame == startFrame && $0.track.id == track.id
                            }) {
                                self.scheduledEntries[idx].endFrame = actualEnd
                            }
                        }
                        self.nextScheduleFrame = actualEnd
                    }

                } catch {
                    if Task.isCancelled { return }
                    print("[PlayerEngine] Error opening \(track.title): \(error)")
                }

                isFirstTrack = false
                // Under repeat-one, re-decode the same track indefinitely instead of
                // advancing. Checked fresh each iteration so toggling repeat-one takes
                // effect on the next loop boundary (rebuildDecodePipeline handles the
                // case where we need to flush already-scheduled next-track audio).
                let repeatOne: Bool = await MainActor.run { [weak self] in
                    self?.isRepeatOne ?? false
                }
                if !repeatOne {
                    trackIndex += 1
                }
            }

            // Task was cancelled mid-decode; make sure isDecoding reflects that.
            await MainActor.run { [weak self] in
                self?.isDecoding = false
            }
        }
    }

    // MARK: - Time tracking tick

    private func startTick() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateTime()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func updateTime() {
        guard let sampleTime = graph.currentPlayerSampleTime(), sampleTime >= 0 else { return }
        let canonicalRate = graph.canonicalFormat.sampleRate

        for entry in scheduledEntries {
            // endFrame == .max means "still decoding" — treat as if it extends to infinity.
            if sampleTime >= entry.startFrame && (entry.endFrame == .max || sampleTime < entry.endFrame) {
                // Detect entry transitions via startFrame, not track.id — under
                // repeat-one the same track.id appears across multiple entries, and
                // we still need to reset seekTimeOffset at each loop boundary.
                if currentEntryStartFrame != entry.startFrame {
                    let isInitialEntry = (currentEntryStartFrame == -1)
                    currentEntryStartFrame = entry.startFrame
                    currentTrack = entry.track
                    if entry.endFrame != .max {
                        duration = entry.track.duration ?? Double(entry.endFrame - entry.startFrame) / canonicalRate
                    } else {
                        duration = entry.track.duration
                    }
                    if let idx = _queue.firstIndex(where: { $0.id == entry.track.id }) {
                        _currentIndex = idx
                    }
                    // Reset seek offset for subsequent entries (they start at 0).
                    // Keep it for the very first entry we land on — that's where an
                    // initial seek position lives.
                    if !isInitialEntry {
                        seekTimeOffset = 0
                    }
                }

                let framesIntoTrack = sampleTime - entry.startFrame
                currentTime = seekTimeOffset + Double(framesIntoTrack) / canonicalRate
                notifyStateUpdate()

                // Clean up fully-consumed, finalized entries.
                while let first = scheduledEntries.first,
                      first.endFrame != .max,
                      first.endFrame <= sampleTime {
                    scheduledEntries.removeFirst()
                }
                return
            }
        }

        // Past all entries and decoding done → playback finished.
        // Only trigger if the last entry is finalized (endFrame != .max).
        if !isDecoding,
           let lastEntry = scheduledEntries.last,
           lastEntry.endFrame != .max,
           sampleTime >= lastEntry.endFrame {
            // Snap currentTime to duration so repeat-end detection works reliably.
            if let d = duration { currentTime = d }
            isPlaying = false
            stopTick()
            notifyStateUpdate()
        }
    }

    // MARK: - Configuration change

    /// Apply a user-chosen output device / rate / bit depth. At launch (graph
    /// not built yet, or nothing queued) this is applied directly with no
    /// audible effect. Mid-playback it's one rebuild that resumes at the same
    /// position. The canonical rate stays fixed afterwards, so gapless
    /// transitions between tracks are unaffected.
    func applyOutputConfiguration(_ config: AudioOutputConfig) {
        guard isPrepared, !_queue.isEmpty else {
            do {
                try graph.applyOutput(config)
            } catch {
                print("[PlayerEngine] Failed to apply output configuration: \(error)")
            }
            if isPrepared {
                throttle.setLimit(Int64(graph.canonicalFormat.sampleRate * 10))
            }
            return
        }
        rebuildOutput {
            do {
                try graph.applyOutput(config)
            } catch {
                print("[PlayerEngine] Failed to apply output configuration: \(error)")
                graph.reprepare()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isPrepared else { return }
        // Our own applyOutputConfiguration() can echo a notification after it
        // has already rebuilt at the new rate — nothing to do then, and a
        // second flush would cost an extra audible restart.
        if graph.isInSyncWithDevice { return }
        rebuildOutput { graph.reprepare() }
    }

    /// Flush everything, let `reconfigure` change the graph, then restart
    /// decoding at the saved position against the (possibly new) canonical rate.
    private func rebuildOutput(_ reconfigure: () -> Void) {
        let wasPlaying = isPlaying
        let savedTime = currentTime
        let savedIndex = _currentIndex

        cancelDecode()
        graph.flush()
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        currentEntryStartFrame = -1

        reconfigure()
        // Update throttle limit for new device rate.
        let rate = graph.canonicalFormat.sampleRate
        throttle.setLimit(Int64(rate * 10))

        if !_queue.isEmpty {
            seekTimeOffset = savedTime
            startDecoding(from: savedIndex, seekOffset: savedTime)
            if wasPlaying { play() }
        }
    }

    // MARK: - Helpers

    private func notifyStateUpdate() {
        onStateUpdate?()
    }
}

// MARK: - Buffer throttle (backpressure)

/// Caps in-flight scheduled frames so we never flood the player node's buffer queue.
/// Thread-safe; used from the decode task and completion callbacks concurrently.
final class BufferThrottle: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ThrottleState())

    private struct ThrottleState {
        var inFlight: Int64 = 0
        var limit: Int64 = 441_000 // default ~10s at 44.1 kHz, updated at prepare
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    func setLimit(_ limit: Int64) {
        state.withLock { $0.limit = limit }
    }

    func acquire(frames: Int64) async {
        let shouldWait: Bool = state.withLock { s in
            s.inFlight += frames
            return s.inFlight > s.limit
        }
        if !shouldWait { return }

        await withCheckedContinuation { cont in
            state.withLock { $0.waiters.append(cont) }
        }
    }

    func release(frames: Int64) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            s.inFlight -= frames
            if s.inFlight <= s.limit, !s.waiters.isEmpty {
                return s.waiters.removeFirst()
            }
            return nil
        }
        waiter?.resume()
    }

    /// Cancel all backpressure — unblock any waiting decode task so it can check cancellation.
    func reset() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.inFlight = 0
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for w in waiters { w.resume() }
    }
}

// MARK: - Concurrency helpers

struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
