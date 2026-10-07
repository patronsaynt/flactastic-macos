import Foundation
import Observation

enum RepeatMode: Sendable {
    case off, all, one
}

@Observable
@MainActor
final class PlayerState {
    let engine: PlayerEngine
    private let nowPlaying: NowPlayingController

    /// Local listening-history recorder. Optional so previews/tests can omit it.
    /// Plays are committed to whichever library this store is currently pointed
    /// at, so switching libraries needs no extra coordination here.
    private let listening: ListeningStore?

    /// Read live so the user's "counted play" threshold (Settings → Config)
    /// takes effect immediately, without restarting playback tracking.
    private let settings: Settings?

    /// The track currently being timed for listening history. A single
    /// `PlayEvent` is emitted when the track stops being current (skip, advance,
    /// end, or repeat). `trackedListened` accumulates only *genuine* playback
    /// time — small forward steps observed while playing — so scrubbing or
    /// clicking through tracks cannot inflate it toward a counted play.
    private var trackedTrack: Track?
    private var trackedStart: Date = .now
    private var trackedListened: TimeInterval = 0
    private var lastObservedTime: TimeInterval = 0

    /// Largest forward jump in playback position (seconds) still credited as
    /// real listening. The engine ticks every ~50 ms, so genuine steps are tiny;
    /// anything larger is a seek/scrub and is not credited.
    private static let maxCreditedStep: TimeInterval = 1.5

    /// Default fraction of a track that must be genuinely heard for it to count
    /// as a play (Spotify counts at ~90%). Used when no Settings is wired.
    private static let defaultCountedPlayFraction: Double = 0.90

    var currentTrack: Track?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var volume: Float = 0.75
    var isShuffleEnabled: Bool = false
    var repeatMode: RepeatMode = .off {
        didSet {
            guard oldValue != repeatMode else { return }
            engine.isRepeatOne = (repeatMode == .one)
        }
    }

    /// The original (unshuffled) queue, stored so we can restore order when shuffle is turned off.
    private var originalQueue: [Track] = []

    /// Track IDs that were added via Play Next / Add to Queue — the queue panel
    /// groups these under "Queued by you". Cleared whenever a fresh queue is started
    /// (e.g. via Play All, a double-click, or track-list playback).
    var userQueuedTrackIDs: Set<UUID> = []

    /// Display name of the source the current queue was started from — e.g. the
    /// album name or playlist name. The queue panel labels the source's tracks
    /// "Playing from <source>".
    var playbackSource: String? = nil

    /// Whether the queue panel is currently visible.
    var isQueueVisible: Bool = false

    /// True while the lyrics sync sheet is up. The app-level spacebar monitor
    /// checks this and steps aside so the sheet can capture beat taps.
    var isLyricsSyncActive: Bool = false

    /// Mirror of `engine.queue`. Stored (not computed) so SwiftUI observes changes
    /// even when `currentTrack`/`duration` don't change — e.g. appending to a
    /// single-track queue, where the current track stays the same but the queue grows.
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0

    func isUserQueued(_ track: Track) -> Bool {
        userQueuedTrackIDs.contains(track.id)
    }

    init(graph: (any AudioGraphProtocol)? = nil,
         listening: ListeningStore? = nil,
         settings: Settings? = nil) {
        engine = PlayerEngine(graph: graph)
        nowPlaying = NowPlayingController()
        self.listening = listening
        self.settings = settings
        engine.onStateUpdate = { [weak self] in
            self?.syncFromEngine()
        }
        // Two-step wiring: NowPlayingController is created above without `self`,
        // then attached once `self` is fully initialized so its remote command
        // closures can reach back into PlayerState.
        nowPlaying.attach(player: self)
    }

    /// Toggle shuffle on/off. Shuffling applies ONLY to source (album/playlist)
    /// tracks — user-queued tracks always retain their "next up" position
    /// immediately after the currently-playing track, in their original order.
    func toggleShuffle() {
        let wasShuffled = isShuffleEnabled
        isShuffleEnabled.toggle()

        let currentQueue = engine.queue
        guard !currentQueue.isEmpty, let playing = currentTrack else { return }
        let curIdx = engine.currentIndex

        // Partition the upcoming portion into user-queued (preserve order) vs source.
        let upcoming: [Track] = (curIdx + 1) < currentQueue.count
            ? Array(currentQueue[(curIdx + 1)...])
            : []
        let userUpcoming = upcoming.filter { userQueuedTrackIDs.contains($0.id) }
        let sourceUpcoming = upcoming.filter { !userQueuedTrackIDs.contains($0.id) }

        if !wasShuffled {
            // Turning ON: snapshot the full queue for later restoration, then
            // rebuild as [current] + [user-queued preserved] + [shuffled rest].
            // The "rest" includes both upcoming source tracks AND tracks that
            // already played before the current one — keeping them in the
            // queue (just at the back of the shuffled section) ensures
            // repeat-all wraps over the entire album/playlist, not only the
            // tail that was upcoming when shuffle was toggled on.
            originalQueue = currentQueue
            let playedSource = curIdx > 0
                ? Array(currentQueue[0..<curIdx]).filter { !userQueuedTrackIDs.contains($0.id) }
                : []
            var shuffledRest = sourceUpcoming + playedSource
            shuffledRest.shuffle()
            let newQueue = [playing] + userUpcoming + shuffledRest
            // reorderQueue rearranges without flushing — playback continues uninterrupted.
            engine.reorderQueue(newQueue, currentIndex: 0)
        } else {
            // Turning OFF: restore source order from originalQueue, keeping
            // any user-queued tracks at "next up" (they're immune to shuffle).
            guard !originalQueue.isEmpty,
                  let origIdx = originalQueue.firstIndex(where: { $0.id == playing.id }) else {
                originalQueue = []
                return
            }
            // Strip any user-queued tracks from the restored source order so
            // they don't appear twice (we re-inject userUpcoming below).
            let before = Array(originalQueue[0..<origIdx])
                .filter { !userQueuedTrackIDs.contains($0.id) }
            let after = Array(originalQueue[(origIdx + 1)...])
                .filter { !userQueuedTrackIDs.contains($0.id) }
            let newQueue = before + [playing] + userUpcoming + after
            engine.reorderQueue(newQueue, currentIndex: before.count)
            originalQueue = []
        }
    }

    /// Advance to the next track, respecting repeat mode.
    func next() {
        let q = engine.queue
        guard !q.isEmpty else { return }
        let nextIndex = engine.currentIndex + 1
        if nextIndex < q.count {
            engine.setQueue(q, startAt: nextIndex)
            engine.play()
        } else if repeatMode == .all {
            engine.setQueue(q, startAt: 0)
            engine.play()
        } else {
            // End of queue, no repeat — stop playback
            engine.pause()
        }
    }

    // MARK: - Queue API

    /// Start a fresh playback queue. Clears any user-queued markers — this is what
    /// Play All, double-click, and similar "start playing X" actions should call
    /// instead of talking to the engine directly.
    ///
    /// When `isShuffleEnabled` is true the queue is automatically shuffled:
    /// the track at `index` plays first, then all other tracks (including those
    /// before `index`) are shuffled behind it, matching Spotify-style behaviour.
    /// The original unshuffled order is snapshot into `originalQueue` so that
    /// toggling shuffle off later can restore it.
    func startFreshQueue(_ tracks: [Track], startAt index: Int = 0, source: String? = nil) {
        userQueuedTrackIDs.removeAll()
        playbackSource = source

        if isShuffleEnabled && tracks.count > 1 {
            // Snapshot the ordered source for later shuffle-off restoration.
            originalQueue = tracks
            // Start with the chosen track; shuffle everything else (including
            // tracks that came before `index` — they stay in the pool).
            let selected = tracks[index]
            var rest = tracks
            rest.remove(at: index)
            rest.shuffle()
            engine.setQueue([selected] + rest, startAt: 0)
        } else {
            originalQueue = []
            engine.setQueue(tracks, startAt: index)
        }
    }

    /// Insert tracks immediately after the current track. If nothing is playing yet,
    /// this starts a fresh queue from the given tracks.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let fresh = tracks.map { $0.withNewID() }
        let ids = fresh.map { $0.id }

        if engine.queue.isEmpty {
            userQueuedTrackIDs = Set(ids)
            playbackSource = nil
            engine.setQueue(fresh, startAt: 0)
            engine.play()
        } else {
            userQueuedTrackIDs.formUnion(ids)
            engine.insertTracks(fresh, at: engine.currentIndex + 1)
        }
    }

    /// Append tracks to the user-queued section — i.e. after the current track and
    /// any already-user-queued tracks, but *before* the remaining source tracks.
    /// If the queue is empty, this behaves like `playNext` and starts playback.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let fresh = tracks.map { $0.withNewID() }
        let ids = fresh.map { $0.id }

        if engine.queue.isEmpty {
            userQueuedTrackIDs = Set(ids)
            playbackSource = nil
            engine.setQueue(fresh, startAt: 0)
            engine.play()
            return
        }

        // Skip past any already-user-queued tracks that sit between the current
        // track and the source section so new additions append to the user-queue
        // section, matching Spotify-style behavior.
        let q = engine.queue
        var insertIdx = engine.currentIndex + 1
        while insertIdx < q.count && userQueuedTrackIDs.contains(q[insertIdx].id) {
            insertIdx += 1
        }

        userQueuedTrackIDs.formUnion(ids)
        if insertIdx >= q.count {
            engine.appendTracks(fresh)
        } else {
            engine.insertTracks(fresh, at: insertIdx)
        }
    }

    /// Move the track identified by `sourceID` to immediately before the track
    /// identified by `destinationID`. Used by the queue panel's drag-to-reorder
    /// drop targets. Both tracks must already exist in the engine queue.
    func moveTrack(withID sourceID: UUID, before destinationID: UUID) {
        var q = engine.queue
        guard let srcIdx = q.firstIndex(where: { $0.id == sourceID }),
              let dstIdx = q.firstIndex(where: { $0.id == destinationID }),
              srcIdx != dstIdx else { return }
        let item = q.remove(at: srcIdx)
        let insertIdx = srcIdx < dstIdx ? dstIdx - 1 : dstIdx
        q.insert(item, at: insertIdx)

        // Fix up the engine's current-index pointer so the same audio keeps
        // playing after the reorder. The current track itself is never
        // draggable from the UI (Now Playing row is moveDisabled), but adjust
        // defensively in case the move shifts it.
        var curIdx = engine.currentIndex
        if srcIdx == curIdx {
            curIdx = insertIdx
        } else {
            if srcIdx < curIdx { curIdx -= 1 }
            if insertIdx <= curIdx { curIdx += 1 }
        }
        engine.reorderQueue(q, currentIndex: curIdx)
    }

    /// Remove the track at the given engine-queue index. Only valid for
    /// upcoming tracks (index > currentIndex); attempts to remove the
    /// currently-playing track or already-played tracks are ignored.
    func removeFromQueue(at engineIndex: Int) {
        let q = engine.queue
        guard engineIndex > engine.currentIndex, engineIndex < q.count else { return }
        userQueuedTrackIDs.remove(q[engineIndex].id)
        engine.removeFromQueue(at: engineIndex)
    }

    /// Drop everything after the current track. The current track keeps
    /// playing; turning shuffle off afterwards won't bring the cleared tracks
    /// back.
    func clearUpcoming() {
        let q = engine.queue
        let cur = engine.currentIndex
        guard cur + 1 < q.count else { return }
        for track in q[(cur + 1)...] { userQueuedTrackIDs.remove(track.id) }
        originalQueue = []
        engine.reorderQueue(Array(q[...cur]), currentIndex: cur)
    }

    /// Jump to a specific index within the current queue.
    func jumpTo(index: Int) {
        let q = engine.queue
        guard index >= 0, index < q.count else { return }
        engine.setQueue(q, startAt: index)
        engine.play()
    }

    /// Emit a `PlayEvent` for the track currently being timed (if any) and clear
    /// the tracking slot. Safe to call repeatedly — a no-op when nothing is
    /// tracked. Call before switching libraries so the in-flight play is
    /// committed to the outgoing library.
    func flushPending() {
        guard let track = trackedTrack else { return }
        let duration = track.duration ?? engine.duration
        // A play "counts" only when the listener genuinely heard ~90% of the
        // track (streaming-service style). `trackedListened` already excludes
        // scrubbed/seek time, so rapid clicking or scrubbing to the end can't
        // satisfy this. Tracks with unknown duration fall back to a flat
        // four-minute floor.
        let fraction = settings?.countedPlayFraction ?? Self.defaultCountedPlayFraction
        let counted: Bool
        if fraction <= 0 {
            // A 0% threshold means any genuine listen counts.
            counted = trackedListened > 0
        } else if let duration, duration > 0 {
            counted = trackedListened >= duration * fraction
        } else {
            // Unknown duration: scale the 4-minute floor by the threshold.
            counted = trackedListened >= 240 * fraction
        }
        listening?.record(
            track: track,
            startedAt: trackedStart,
            secondsListened: trackedListened,
            counted: counted
        )
        trackedTrack = nil
        trackedListened = 0
        lastObservedTime = 0
    }

    /// Keep the listening-history tracker in sync with the engine: accumulate
    /// genuine listening time for the current track, and flush + re-arm whenever
    /// the current track changes (skip, advance, or queue cleared) — or when the
    /// same track restarts from the top under repeat-one / repeat-all, so each
    /// replay is recorded as its own play.
    private func updateListeningTracker() {
        let engineTrack = engine.currentTrack
        let now = engine.currentTime

        if engineTrack?.id != trackedTrack?.id {
            flushPending()
            arm(engineTrack)
            return
        }
        guard trackedTrack != nil else { return }

        // Detect a repeat: playback jumped from near the end back to the start.
        // Restrict to that end→start pattern so ordinary backward scrubbing
        // isn't miscounted as a fresh play.
        let duration = trackedTrack?.duration ?? engine.duration
        if let duration, duration > 0,
           lastObservedTime >= duration - 2.0, now < 2.0 {
            flushPending()
            arm(engineTrack)
            return
        }

        // Credit only small forward steps taken while actually playing. Seeks
        // (large jumps, forward or back) and paused ticks contribute nothing.
        let step = now - lastObservedTime
        if engine.isPlaying, step > 0, step <= Self.maxCreditedStep {
            trackedListened += step
        }
        lastObservedTime = now
    }

    /// Begin timing `track` for listening history.
    private func arm(_ track: Track?) {
        guard let track else { return }
        trackedTrack = track
        trackedStart = .now
        trackedListened = 0
        lastObservedTime = engine.currentTime
    }

    private func syncFromEngine() {
        updateListeningTracker()
        // `@Observable` fires invalidations on every assignment regardless of
        // value equality, and this runs on every 50 ms engine tick — so only
        // write properties that actually changed, or every view observing any
        // of them re-renders 20×/s for the whole duration of playback.
        // `currentTime` is the one field that genuinely changes per tick.
        if currentTrack?.id != engine.currentTrack?.id { currentTrack = engine.currentTrack }
        if isPlaying != engine.isPlaying { isPlaying = engine.isPlaying }
        currentTime = engine.currentTime
        if duration != engine.duration { duration = engine.duration }
        if volume != engine.volume { volume = engine.volume }
        // Compare by count + ids: queue mutations are structural (set/append/
        // insert/remove), and comparing full `Track` values would hash/equate
        // multi-MB artwork `Data` blobs every tick.
        if queue.count != engine.queue.count
            || !zip(queue, engine.queue).allSatisfy({ $0.id == $1.id }) {
            queue = engine.queue
        }
        if currentIndex != engine.currentIndex { currentIndex = engine.currentIndex }
        // Push metadata + playback state into MPNowPlayingInfoCenter so
        // Control Center, the lock screen, hardware remotes, and AirPods all
        // see accurate info without needing to poll us.
        nowPlaying.updateNowPlaying(
            track: currentTrack,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration
        )
    }
}
