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

    /// Files playback depends on right now (standardized paths): the playing
    /// track, every track whose audio is scheduled or still being read, and,
    /// on a cast device, the one armed to play next. Writing tags into one of
    /// these rewrites it under the decoder, so `PlaybackFileGuard` waits.
    var filesInUse: Set<String> {
        // The queue ran out: the last track is still "current" but done.
        if hasFinished { return [] }
        var paths = Set(scheduledEntries.map { $0.track.url.standardizedFileURL.path })
        if let currentTrack { paths.insert(currentTrack.url.standardizedFileURL.path) }
        if remote != nil, let next = remoteNextTrack { paths.insert(next.url.standardizedFileURL.path) }
        return paths
    }

    // MARK: - State update callback

    var onStateUpdate: (@MainActor () -> Void)?

    /// Opens tracks that aren't plain local files (a server library's
    /// streams), starting at the given second. Nil, or a nil result, means
    /// read `track.url` with `AVAudioFile`.
    var sourceOpener: (@Sendable (Track, TimeInterval) async throws -> (any PCMSource)?)?

    /// Told the playing track and the one after it whenever either changes,
    /// so a server stream can preload the next and drop the rest.
    var upcoming: ((Track?, Track?) -> Void)?
    /// Playback ran dry mid-track (a stream that can't keep up).
    var stalled: (() -> Void)?
    private var lastUpcoming: (URL?, URL?) = (nil, nil)

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
    /// The track the decode pass is reading (or about to open). The pass
    /// finds each next track by looking up the one it just read in the queue
    /// as it stands then, so a queue edit only needs the pass replaced when
    /// it reorders audio that's already loaded (see `loadedOrderHolds`).
    private var decodingTrackID: UUID?
    private var seekTimeOffset: TimeInterval = 0
    /// The queue played to its end (cleared when anything starts again).
    private var hasFinished = false
    /// Playing, but the node is held because the decoder hasn't delivered
    /// (a stream opening, a seek into a transcode, a slow network). See
    /// `holdWhileStarved`.
    private(set) var isHolding = false
    /// Seconds queued before a held node plays again. Short when starting
    /// or seeking, so playback is quick to begin; longer after running dry
    /// mid-song, so a slow link refills properly instead of stuttering
    /// (play, run dry, hold, play…). ExoPlayer uses 2.5 s and 5 s.
    private var resumeSeconds = PlayerEngine.startSeconds
    static let startSeconds = 0.5
    static let rebufferSeconds = 4.0
    /// A stream whose queued audio falls from `healthySeconds` to
    /// `lowSeconds` while it plays is told early (`stalled`), before it runs
    /// dry: Automatic quality drops then, mid-track, and only then.
    static let healthySeconds = 5.0
    static let lowSeconds = 2.0
    private var bufferWasHealthy = false

    /// Tracks which scheduled entry playback is currently inside (by its startFrame).
    /// Used to detect entry transitions — including loops of the same track under
    /// repeat-one — so we can reset seekTimeOffset at boundaries.
    private var currentEntryStartFrame: AVAudioFramePosition = -1

    /// When true, the decode task re-schedules the current track indefinitely
    /// instead of advancing to the next.
    var isRepeatOne: Bool = false {
        didSet {
            guard oldValue != isRepeatOne, !_queue.isEmpty else { return }
            if remote != nil {
                remoteQueueDidChange()
                return
            }
            guard isPrepared else { return }
            if isRepeatOne {
                // Only flush if a different track has already been pre-scheduled.
                // With the throttle capped at ~10 s, this only happens for short tracks
                // or when the user toggles repeat right at the end of one. For typical
                // music tracks (> 10 s) the decode task is still on the current track,
                // so we can just let it pick up isRepeatOne naturally — no cut.
                if decoderIsPastCurrent {
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
        var source: PlaybackSource? = nil
    }

    /// Where the playing track comes from, for a server library (offline
    /// copy, stream, or transcode). Nil for local files. Switches with the
    /// track itself, not when the next one is read ahead.
    private(set) var currentSource: PlaybackSource?

    // MARK: - Remote playback state

    /// The network device playing in place of the local graph, if any.
    private(set) var remote: (any RemotePlaybackTarget)?
    var isRemote: Bool { remote != nil }

    /// Remote position is reported roughly once a second; between reports the
    /// tick interpolates from this anchor so the seek bar stays smooth.
    private var remoteAnchorTime: TimeInterval = 0
    private var remoteAnchorDate: Date?

    /// False from the moment we ask the device to start (load, play, seek)
    /// until it reports it is actually playing. Speakers buffer for a few
    /// seconds first; the clock stays frozen meanwhile so the seek bar never
    /// runs ahead of what's audible.
    private var remoteClockConfirmed = false

    /// Playing was requested but the device hasn't started yet.
    var isAwaitingRemoteStart: Bool { remote != nil && isPlaying && !remoteClockConfirmed }

    /// Local volume saved while the slider drives the remote device's volume.
    private var localVolume: Float = 0.75

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
        if !tracks.isEmpty { PlaybackTrace.begin("play") }
        hasFinished = false
        if let remote {
            _queue = tracks
            _currentIndex = min(index, max(tracks.count - 1, 0))
            currentTrack = _queue.isEmpty ? nil : _queue[_currentIndex]
            duration = currentTrack?.duration
            currentTime = 0
            if _queue.isEmpty { isPlaying = false; stopTick() }
            remoteClockConfirmed = false
            setRemoteAnchor(0)
            notifyStateUpdate()
            if let track = currentTrack {
                remote.load(track, next: remoteNextTrack, startAt: 0, autoplay: isPlaying)
            }
            return
        }
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
            currentSource = nil
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
        hasFinished = false
        if let remote {
            guard currentTrack != nil else { return }
            remote.play()
            isPlaying = true
            remoteClockConfirmed = false
            setRemoteAnchor(currentTime)
            startTick()
            notifyStateUpdate()
            return
        }
        ensurePrepared()
        isPlaying = true
        isHolding = false
        resumeSeconds = Self.startSeconds
        if isStarved {
            isHolding = true
            stopTick() // so the quicker cadence starts now, not after a sleep
        } else {
            graph.play()
        }
        startTick()
        notifyStateUpdate()
    }

    /// Less than a quarter second queued while more is still being decoded.
    private var isStarved: Bool {
        isDecoding && throttle.inFlightFrames < AVAudioFramePosition(graph.canonicalFormat.sampleRate / 4)
    }

    /// The node's clock, which the scrubber follows, keeps counting while the
    /// node runs with nothing queued. A local file is decoded in milliseconds;
    /// a stream can take a moment (opening, a seek into a transcode, a slow
    /// network), and the scrubber would run ahead of the audio by that much.
    /// So the node is held, clock frozen, until a second of audio is queued
    /// again. Nothing is cut: a held node keeps what it has.
    private func holdWhileStarved() {
        let queued = Double(throttle.inFlightFrames) / graph.canonicalFormat.sampleRate
        if queued >= Self.healthySeconds {
            bufferWasHealthy = true
        } else if bufferWasHealthy, !isHolding, isDecoding, queued < Self.lowSeconds {
            bufferWasHealthy = false
            stalled?()
        }
        if !isHolding, isStarved {
            graph.pause()
            isHolding = true
            resumeSeconds = Self.rebufferSeconds
            stalled?()
            notifyStateUpdate()
        } else if isHolding,
                  !isDecoding || throttle.inFlightFrames >= AVAudioFramePosition(graph.canonicalFormat.sampleRate * resumeSeconds) {
            graph.play()
            PlaybackTrace.mark("output")
            isHolding = false
            notifyStateUpdate()
        }
    }

    func pause() {
        if let remote {
            remote.pause()
            isPlaying = false
            setRemoteAnchor(currentTime)
            stopTick()
            notifyStateUpdate()
            return
        }
        graph.pause()
        isPlaying = false
        isHolding = false
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
        if remote != nil {
            if _queue.isEmpty {
                setQueue(tracks, startAt: 0)
            } else {
                _queue.append(contentsOf: tracks)
                remoteQueueDidChange()
            }
            return
        }
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

        if remote != nil {
            remoteQueueDidChange()
            return
        }

        // Inserted after everything already loaded: the decoder finds the new
        // tracks when it gets there (or starts on them, if it was idle).
        if loadedOrderHolds {
            notifyStateUpdate()
            resumeDecoderIfIdle()
            return
        }

        // Inserted between tracks already loaded into the node — flush and rebuild.
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

    /// Point queued tracks at files that moved on disk (an Organizer run),
    /// keyed by old absolute path. The queue holds its own copies of each
    /// track — queued ones even get fresh IDs — so without this every
    /// upcoming track still names a path that no longer exists: the playing
    /// song finishes (its file is already open), then each next track fails
    /// to open and playback stops, and skipping fails the same way.
    func relocate(_ newURLByOldPath: [String: URL]) {
        guard !newURLByOldPath.isEmpty else { return }
        // The Organizer keys its moves by standardized path; compare like
        // for like, so a path spelled with "." or "//" still matches.
        let byPath = Dictionary(newURLByOldPath.map { (URL(fileURLWithPath: $0.key).standardizedFileURL.path, $0.value) },
                                uniquingKeysWith: { a, _ in a })
        func moved(_ track: Track) -> Track {
            byPath[track.url.standardizedFileURL.path].map { track.withURL($0) } ?? track
        }
        _queue = _queue.map(moved)
        currentTrack = currentTrack.map(moved)
        scheduledEntries = scheduledEntries.map {
            ScheduledEntry(track: moved($0.track), startFrame: $0.startFrame, endFrame: $0.endFrame, source: $0.source)
        }
        notifyStateUpdate()

        if remote != nil {
            remoteQueueDidChange()
            return
        }
        // The decoder reads each track's URL from the queue as it reaches it,
        // so a running pass picks the new paths up by itself. One that already
        // hit the old paths gave up and went idle: restart it after the last
        // track it did get into the player.
        resumeDecoderIfIdle()
    }

    /// Remove a single upcoming track from the queue without interrupting
    /// playback. Falls back to a flush only when the removed track's audio is
    /// already loaded into the player node.
    func removeFromQueue(at index: Int) {
        guard index > _currentIndex, index < _queue.count else { return }

        if remote != nil {
            _queue.remove(at: index)
            remoteQueueDidChange()
            return
        }

        _queue.remove(at: index)

        // The removed track isn't among those loaded: the decoder reads what
        // follows from the queue when it gets there. Nothing to restart.
        if loadedOrderHolds {
            notifyStateUpdate()
            return
        }

        // Fallback: the removed track's audio is already in the player node —
        // flush and rebuild to restore correct order.
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

    /// How far `currentTime` runs ahead of what's audible. `currentTime`
    /// tracks the player node's render position; the listener hears it one
    /// output latency later. Zero for remote playback, whose position is
    /// reported by the device itself.
    var outputLatency: TimeInterval {
        remote == nil ? graph.outputLatency : 0
    }

    func seek(to seconds: TimeInterval) {
        PlaybackTrace.begin("seek")
        guard !_queue.isEmpty else { return }
        if let remote {
            let clamped = max(0, seconds)
            currentTime = clamped
            remoteClockConfirmed = false
            setRemoteAnchor(clamped)
            remote.seek(to: clamped)
            notifyStateUpdate()
            return
        }
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
        if let remote {
            // The stream stays bit-perfect: volume is applied on the device.
            remote.setVolume(volume)
        } else {
            graph.setOutputVolume(volume)
        }
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

    /// Rearrange the queue (drags, shuffle on/off) without touching the audio.
    /// The decoder finds each next track by the one it just read, so the new
    /// order takes effect by itself. Only when the edit reorders audio that's
    /// already loaded (the last ~10 s of a track, with the next one read
    /// ahead) is the pipeline rebuilt — a brief, unavoidable cut.
    func reorderQueue(_ tracks: [Track], currentIndex: Int) {
        guard !tracks.isEmpty else { return }
        _queue = tracks
        _currentIndex = currentIndex

        if remote != nil {
            remoteQueueDidChange()
            return
        }
        guard isPrepared else { notifyStateUpdate(); return }

        if !loadedOrderHolds {
            rebuildDecodePipeline()
            return
        }
        notifyStateUpdate()
        // A played track dragged after the last one loaded gives an idle
        // decoder something to read.
        resumeDecoderIfIdle()
    }

    /// Where `id` sits in the queue: at `near` if it's there, else its closest
    /// copy. A playlist can list the same song twice under one ID, and the
    /// first copy is the wrong one when the second is playing.
    private func queueIndex(of id: UUID, near: Int) -> Int? {
        if _queue.indices.contains(near), _queue[near].id == id { return near }
        return _queue.indices.filter { _queue[$0].id == id }.min { abs($0 - near) < abs($1 - near) }
    }

    /// The tracks whose audio is loaded from the playing one on, plus the one
    /// being read — in play order, repeats (repeat-one) collapsed.
    private var loadedTrackIDs: [UUID] {
        var ids: [UUID] = []
        for e in scheduledEntries where e.endFrame == .max || e.startFrame >= currentEntryStartFrame {
            if ids.last != e.track.id { ids.append(e.track.id) }
        }
        if isDecoding, let d = decodingTrackID, ids.last != d { ids.append(d) }
        return ids
    }

    /// Whether the edited queue still plays the loaded tracks back to back,
    /// from the playing one, in the order they're loaded. If so, an edit
    /// can't disturb them.
    private var loadedOrderHolds: Bool {
        let ids = loadedTrackIDs
        guard let first = ids.first else { return true }
        guard let start = queueIndex(of: first, near: _currentIndex) else { return false }
        for (k, id) in ids.enumerated() where start + k >= _queue.count || _queue[start + k].id != id {
            return false
        }
        return true
    }

    /// The decoder has moved on from the playing track (the next is read ahead).
    private var decoderIsPastCurrent: Bool {
        loadedTrackIDs.contains { $0 != currentTrack?.id }
    }

    /// An idle decoder (it reached the queue's end) starts on whatever now
    /// follows the last track it loaded.
    private func resumeDecoderIfIdle() {
        guard !isDecoding, let last = scheduledEntries.last, last.endFrame != .max,
              let lastIndex = queueIndex(of: last.track.id, near: _currentIndex),
              lastIndex + 1 < _queue.count else { return }
        startDecoding(from: lastIndex + 1)
    }

    private func cancelDecode() {
        decodeTask?.cancel()
        decodeTask = nil
        generation.withLock { $0 &+= 1 }
        throttle.reset()
        bufferWasHealthy = false
        isDecoding = false
        decodingTrackID = nil
    }

    private func startDecoding(from index: Int, seekOffset: TimeInterval = 0) {
        let canonical = graph.canonicalFormat
        let readChunk = readChunkFrames
        let outputChunk = outputChunkFrames
        let graphRef = graph
        let throttle = self.throttle
        let myGeneration = generation.withLock { $0 }
        let generation = self.generation
        let scheduleEnd = self.liveScheduleEnd  // captured by reference (struct wraps OS pointer)
        let opener = sourceOpener
        // A pass started for upcoming tracks (append/insert while the decoder is
        // idle) begins at a track that isn't playing yet — its length must not
        // replace the playing track's duration, or the seek bar jumps.
        let startsAtCurrentTrack = index == _currentIndex

        isDecoding = true

        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Where to read when the last track is no longer in the queue (or
            // on the first pass); otherwise the next track follows the last.
            var trackIndex = index
            var isFirstTrack = true
            var lastTrackID: UUID?
            // Move on even under repeat-one (the track couldn't be read).
            var forceAdvance = false
            // A track whose file failed mid-read (rewritten on disk by a tag
            // edit while it played, say): reopened and read on from where it
            // stopped, into the same entry. Nil for a track starting fresh.
            var resume: (startFrame: AVAudioFramePosition, scheduled: AVAudioFramePosition, seconds: TimeInterval, attempts: Int)?

            while !Task.isCancelled {
                // Read the current queue entry live on each iteration so appended
                // tracks are picked up without restarting the decode task.
                // Also atomically clear isDecoding when the queue is exhausted so
                // appendTracks() on the main actor can reliably detect idle.
                // Every hop to the main actor re-checks the generation there: a
                // seek or skip can replace this pass while it waits to hop, and
                // a stale pass must not touch the new one's state.
                // -1: one on, unless repeat-one is on (checked live there).
                let step = resume != nil ? 0 : (forceAdvance ? 1 : -1)
                let fetched: (Track, Int)? = await MainActor.run { [weak self, trackIndex, lastTrackID, step] () -> (Track, Int)? in
                    guard let self, generation.withLock({ $0 }) == myGeneration else { return nil }
                    var i = trackIndex
                    if let lastTrackID, let at = self.queueIndex(of: lastTrackID, near: trackIndex) {
                        i = at + (step >= 0 ? step : (self.isRepeatOne ? 0 : 1))
                    }
                    if i >= self._queue.count {
                        self.isDecoding = false
                        self.decodingTrackID = nil
                        return nil
                    }
                    self.decodingTrackID = self._queue[i].id
                    return (self._queue[i], i)
                }
                guard let (track, at) = fetched else { return }
                trackIndex = at
                lastTrackID = track.id
                forceAdvance = false

                var startFrame: AVAudioFramePosition = resume?.startFrame ?? 0
                var totalScheduledFrames: AVAudioFramePosition = resume?.scheduled ?? 0
                var entryOpened = resume != nil
                do {
                    let file: any PCMSource
                    let startSeconds = resume?.seconds ?? (isFirstTrack ? seekOffset : 0)
                    if let opened = try await opener?(track, startSeconds) {
                        file = opened
                    } else {
                        file = try AVAudioFile(forReading: track.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                    }
                    let sourceFormat = file.processingFormat

                    // Seek within the first track, or back to where a failed read stopped.
                    if let resume {
                        let seekFrame = AVAudioFramePosition(resume.seconds * sourceFormat.sampleRate)
                        file.framePosition = max(0, min(seekFrame, file.length - 1))
                    } else if isFirstTrack && seekOffset > 0 {
                        let seekFrame = AVAudioFramePosition(seekOffset * sourceFormat.sampleRate)
                        file.framePosition = max(0, min(seekFrame, file.length - 1))
                    }

                    // Update duration for the current track.
                    let fileDuration = Double(file.length) / sourceFormat.sampleRate
                    if isFirstTrack && startsAtCurrentTrack && resume == nil {
                        await MainActor.run { [weak self] in
                            guard generation.withLock({ $0 }) == myGeneration else { return }
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
                            forceAdvance = true
                            isFirstTrack = false
                            continue
                        }
                        conv.sampleRateConverterQuality = .max
                        converter = conv
                    }

                    // Create entry eagerly so updateTime() can track this track immediately.
                    // endFrame = .max is a sentinel meaning "still decoding".
                    if resume == nil {
                        let source = file.playbackSource
                        startFrame = await MainActor.run { [weak self] () -> AVAudioFramePosition in
                            guard let self, generation.withLock({ $0 }) == myGeneration else { return -1 }
                            let sf = self.nextScheduleFrame
                            self.scheduledEntries.append(ScheduledEntry(track: track, startFrame: sf, endFrame: .max, source: source))
                            scheduleEnd.withLock { $0 = sf }
                            return sf
                        }
                        if startFrame < 0 { return }
                    } else {
                        // Reopened mid-track, perhaps at another quality: the mark follows.
                        let source = file.playbackSource, sf = startFrame
                        await MainActor.run { [weak self] in
                            guard let self, generation.withLock({ $0 }) == myGeneration,
                                  let i = self.scheduledEntries.lastIndex(where: { $0.startFrame == sf && $0.track.id == track.id }),
                                  self.scheduledEntries[i].source != source else { return }
                            self.scheduledEntries[i].source = source
                            if self.currentEntryStartFrame == sf { self.currentSource = source; self.notifyStateUpdate() }
                        }
                    }
                    entryOpened = true
                    let startFrame = startFrame

                    if needsConverter, let converter {
                        // --- Converter path: pull-based conversion ---
                        let fileBox = UncheckedSendableBox(file)
                        let readFailure = ReadFailure()
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
                                    readFailure.error = error
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

                                PlaybackTrace.mark("decoded")
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
                        if let error = readFailure.error { throw error }
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

                            PlaybackTrace.mark("decoded")
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
                        if let idx = self.scheduledEntries.firstIndex(where: {
                            $0.startFrame == startFrame && $0.track.id == track.id
                        }) {
                            self.scheduledEntries[idx].endFrame = actualEnd
                        }
                        self.nextScheduleFrame = actualEnd
                    }

                    resume = nil
                } catch {
                    if Task.isCancelled { return }
                    if generation.withLock({ $0 }) != myGeneration { return }
                    let attempts = (resume?.attempts ?? 0) + 1
                    if entryOpened, attempts <= 3 {
                        // The file changed under the decoder (a tag edit rewrote
                        // it in place). Its audio is the same, so wait for the
                        // write to finish, then reopen it and read on from the
                        // same point in time, into the same entry.
                        print("[PlayerEngine] Reading \(track.title) failed; reopening (attempt \(attempts)): \(error)")
                        let base = resume?.seconds ?? (isFirstTrack ? seekOffset : 0)
                        let alreadyCounted = resume?.scheduled ?? 0
                        let seconds = base + Double(totalScheduledFrames - alreadyCounted) / canonical.sampleRate
                        resume = (startFrame, totalScheduledFrames, seconds, attempts)
                        try? await Task.sleep(for: .milliseconds(250 * attempts))
                        continue
                    }
                    if FileManager.default.fileExists(atPath: track.url.path) {
                        print("[PlayerEngine] Couldn't read \(track.title): \(error)")
                    } else {
                        // CoreAudio reports a missing file as an opaque 'wht?'
                        // (2003334207); say what it actually means.
                        print("[PlayerEngine] Couldn't read \(track.title): no file at \(track.url.path) — moved or renamed since it was queued")
                    }
                    resume = nil
                    forceAdvance = true
                    // Close its entry at what was scheduled, so the clock moves
                    // on to the next track at the right frame instead of
                    // leaving the broken one "playing" forever.
                    if entryOpened {
                        let actualEnd = startFrame + totalScheduledFrames
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            if let idx = self.scheduledEntries.firstIndex(where: { $0.track.id == track.id && $0.endFrame == .max }) {
                                self.scheduledEntries[idx].endFrame = actualEnd
                            }
                            self.nextScheduleFrame = actualEnd
                        }
                    }
                }

                // The next pass looks this track up in the queue as it stands
                // then; repeat-one (checked there, live) reads it again.
                isFirstTrack = false
            }

            // Task was cancelled mid-decode; make sure isDecoding reflects that.
            await MainActor.run { [weak self] in
                self?.isDecoding = false
            }
        }
    }

    // MARK: - Remote playback

    /// Hand playback to `target`, continuing the current track at the current
    /// position. `volume` is the device's own volume (nil if it has none);
    /// the local volume is restored on detach.
    func attachRemote(_ target: any RemotePlaybackTarget, volume remoteVolume: Float?) {
        let wasPlaying = isPlaying
        let resumeAt = currentTime
        if remote == nil {
            localVolume = volume
            stopLocalOutput()
        }
        remote = target
        if let remoteVolume { volume = max(0, min(1, remoteVolume)) }
        isPlaying = wasPlaying && currentTrack != nil
        remoteClockConfirmed = false
        setRemoteAnchor(resumeAt)
        if isPlaying { startTick() }
        notifyStateUpdate()
        if let track = currentTrack {
            target.load(track, next: remoteNextTrack, startAt: resumeAt, autoplay: isPlaying)
        }
    }

    /// Return playback to the local graph at the last known remote position.
    func detachRemote(resumePlaying: Bool) {
        guard remote != nil else { return }
        let resumeAt = currentTime
        let shouldPlay = isPlaying && resumePlaying
        remote = nil
        remoteAnchorDate = nil
        stopTick()
        isPlaying = false
        volume = localVolume
        graph.setOutputVolume(localVolume)

        guard !_queue.isEmpty else {
            notifyStateUpdate()
            return
        }
        setQueue(_queue, startAt: _currentIndex)
        if resumeAt > 0 { seek(to: resumeAt) }
        if shouldPlay { play() }
    }

    /// Position / play-state report from the device. Small drift is ignored so
    /// coarse (whole-second) device clocks don't make the seek bar jitter.
    func remoteDidReport(position: TimeInterval?, isPlaying playing: Bool) {
        guard remote != nil, currentTrack != nil else { return }
        let starting = playing && !remoteClockConfirmed
        if let position, starting || abs(position - currentTime) > 1.5 || playing != isPlaying {
            currentTime = position
        }
        if playing { remoteClockConfirmed = true }
        if playing != isPlaying {
            isPlaying = playing
            playing ? startTick() : stopTick()
        }
        setRemoteAnchor(currentTime)
        notifyStateUpdate()
    }

    /// The device moved on to the pre-armed next track by itself (gapless).
    func remoteDidAdvance() {
        guard remote != nil, !_queue.isEmpty else { return }
        if !isRepeatOne {
            guard _currentIndex + 1 < _queue.count else { return }
            _currentIndex += 1
        }
        currentTrack = _queue[_currentIndex]
        duration = currentTrack?.duration
        currentTime = 0
        setRemoteAnchor(0)
        notifyStateUpdate()
        remote?.setNext(remoteNextTrack)
    }

    /// The device stopped at the end of a track without advancing. Load the
    /// next track explicitly, or finish — the UI's repeat-all handling then
    /// takes over exactly as it does for local playback.
    func remoteDidReachEnd() {
        guard let remote, !_queue.isEmpty else { return }
        if remoteNextTrack != nil {
            if !isRepeatOne { _currentIndex += 1 }
            currentTrack = _queue[_currentIndex]
            duration = currentTrack?.duration
            currentTime = 0
            remoteClockConfirmed = false
            setRemoteAnchor(0)
            notifyStateUpdate()
            if let track = currentTrack {
                remote.load(track, next: remoteNextTrack, startAt: 0, autoplay: true)
            }
        } else {
            if let duration { currentTime = duration }
            hasFinished = true
            isPlaying = false
            setRemoteAnchor(currentTime)
            stopTick()
            notifyStateUpdate()
        }
    }

    /// What should follow the current track on the device.
    private var remoteNextTrack: Track? {
        guard !_queue.isEmpty else { return nil }
        if isRepeatOne { return currentTrack }
        let next = _currentIndex + 1
        return next < _queue.count ? _queue[next] : nil
    }

    private func remoteQueueDidChange() {
        notifyStateUpdate()
        remote?.setNext(remoteNextTrack)
    }

    private func setRemoteAnchor(_ time: TimeInterval) {
        remoteAnchorTime = time
        remoteAnchorDate = isPlaying && remoteClockConfirmed ? Date() : nil
    }

    private func updateRemoteTime() {
        guard let anchor = remoteAnchorDate else { return }
        var time = remoteAnchorTime + Date().timeIntervalSince(anchor)
        if let duration { time = min(time, duration) }
        currentTime = time
        notifyStateUpdate()
    }

    /// Silence the local graph and drop everything scheduled on it.
    private func stopLocalOutput() {
        cancelDecode()
        stopTick()
        if isPrepared {
            graph.flush()
            graph.pause()
        }
        scheduledEntries.removeAll()
        nextScheduleFrame = 0
        liveScheduleEnd.withLock { $0 = 0 }
        currentEntryStartFrame = -1
    }

    // MARK: - Time tracking tick

    private func startTick() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateTime()
                // Quicker while waiting to start, so audio goes out as soon as it's ready.
                try? await Task.sleep(for: .milliseconds(self?.isHolding == true ? 5 : 50))
            }
        }
    }

    private func stopTick() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func updateTime() {
        if remote != nil {
            updateRemoteTime()
            return
        }
        if isPlaying { holdWhileStarved() }
        if isHolding { return }
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
                    currentSource = entry.source
                    if entry.endFrame != .max {
                        duration = entry.track.duration ?? Double(entry.endFrame - entry.startFrame) / canonicalRate
                    } else {
                        duration = entry.track.duration
                    }
                    if let idx = queueIndex(of: entry.track.id, near: isInitialEntry ? _currentIndex : _currentIndex + 1) {
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
            hasFinished = true
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
        // While a remote device plays, the local graph is idle — reroute it
        // directly so detaching resumes on the right device.
        guard isPrepared, !_queue.isEmpty, remote == nil else {
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
        if remote != nil {
            reconfigure()
            throttle.setLimit(Int64(graph.canonicalFormat.sampleRate * 10))
            return
        }
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
        let next = _currentIndex + 1 < _queue.count ? _queue[_currentIndex + 1] : nil
        if lastUpcoming.0 != currentTrack?.url || lastUpcoming.1 != next?.url {
            lastUpcoming = (currentTrack?.url, next?.url)
            upcoming?(currentTrack, next)
        }
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

    /// Frames scheduled on the node and not yet consumed.
    var inFlightFrames: Int64 { state.withLock { $0.inFlight } }

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

/// A read error raised inside a converter's input block, carried out of it.
private final class ReadFailure: @unchecked Sendable {
    var error: Error?
}

struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
