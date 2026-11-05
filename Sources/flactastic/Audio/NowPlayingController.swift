import Foundation
import MediaPlayer
import AppKit

/// Bridges `PlayerEngine` ↔ macOS `MediaPlayer` framework so that hardware media
/// keys, Control Center's Now Playing widget, AirPods/Bluetooth headset buttons,
/// and Siri can control playback and display the current track's metadata.
///
/// Wiring:
/// - OS → App: remote command handlers on `MPRemoteCommandCenter` route into
///   `PlayerState` / `PlayerEngine`.
/// - App → OS: `updateNowPlaying(...)` pushes title / artist / album / artwork /
///   elapsed time / play state into `MPNowPlayingInfoCenter`.
///
/// Instances are owned by `PlayerState`. The controller holds a *weak* reference
/// back to `PlayerState`, so remote command closures do not form a retain cycle.
@MainActor
final class NowPlayingController {
    private weak var player: PlayerState?

    /// `MPMediaItemArtwork` is expensive to construct (keeps a closure that
    /// decodes image data on demand). Cache by track id so we only rebuild when
    /// the current track actually changes — `syncFromEngine` fires ~10 times a
    /// second during playback.
    private var cachedArtworkTrackID: UUID?
    private var cachedArtwork: MPMediaItemArtwork?

    /// Last state pushed to `MPNowPlayingInfoCenter`, used to skip redundant
    /// pushes: the OS extrapolates elapsed time from `playbackRate` on its own,
    /// so re-sending the dictionary on every engine tick (~20×/s) is pure churn.
    /// We only push when the track, play state, or duration changes — or when
    /// the real elapsed time drifts from that linear extrapolation (a seek).
    private var lastPushedTrackID: UUID?
    private var lastPushedIsPlaying: Bool?
    private var lastPushedDuration: TimeInterval?
    private var lastPushedElapsed: TimeInterval = 0
    private var lastPushDate: Date = .distantPast

    /// Elapsed-time drift (seconds) beyond which we re-push — i.e. seek detection.
    private static let elapsedDriftTolerance: TimeInterval = 1.0

    init() {
        setupRemoteCommands()
    }

    /// Two-step init: `PlayerState` must construct the controller before it can
    /// pass `self` in. Called immediately after `init`.
    func attach(player: PlayerState) {
        self.player = player
    }

    // MARK: - App → OS

    func updateNowPlaying(track: Track?,
                         isPlaying: Bool,
                         currentTime: TimeInterval,
                         duration: TimeInterval?) {
        guard let track else {
            clear()
            return
        }

        let expectedElapsed = lastPushedElapsed
            + (lastPushedIsPlaying == true ? Date.now.timeIntervalSince(lastPushDate) : 0)
        let stateChanged = track.id != lastPushedTrackID
            || isPlaying != lastPushedIsPlaying
            || duration != lastPushedDuration
        let seeked = abs(currentTime - expectedElapsed) > Self.elapsedDriftTolerance
        guard stateChanged || seeked else { return }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.title
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let artwork = artwork(for: track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // macOS requires explicit playbackState — unlike iOS, `nowPlayingInfo`
        // alone does not drive the Control Center widget.
        center.playbackState = isPlaying ? .playing : .paused

        lastPushedTrackID = track.id
        lastPushedIsPlaying = isPlaying
        lastPushedDuration = duration
        lastPushedElapsed = currentTime
        lastPushDate = .now
    }

    func clear() {
        // `lastPushedIsPlaying == nil` doubles as "already cleared", so the
        // per-tick call while stopped doesn't hit the info center repeatedly.
        guard lastPushedIsPlaying != nil || cachedArtwork != nil else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        cachedArtworkTrackID = nil
        cachedArtwork = nil
        lastPushedTrackID = nil
        lastPushedIsPlaying = nil
        lastPushedDuration = nil
        lastPushedElapsed = 0
        lastPushDate = .distantPast
    }

    // MARK: - OS → App (remote commands)

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.engine.play() }
            return .success
        }

        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.engine.pause() }
            return .success
        }

        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.engine.togglePlayPause() }
            return .success
        }

        // Route "next" through PlayerState so repeat-all (and future queue
        // logic) is respected — `PlayerEngine.next()` alone just stops at the
        // end of the queue.
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.next() }
            return .success
        }

        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.engine.previous() }
            return .success
        }

        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = seekEvent.positionTime
            MainActor.assumeIsolated { self?.player?.engine.seek(to: target) }
            return .success
        }

        // Explicitly disable the commands we don't support so they don't show
        // as ghost controls in Control Center or on hardware remotes.
        c.bookmarkCommand.isEnabled = false
        c.ratingCommand.isEnabled = false
        c.likeCommand.isEnabled = false
        c.dislikeCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.changePlaybackRateCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
    }

    // MARK: - Artwork cache

    private func artwork(for track: Track) -> MPMediaItemArtwork? {
        if cachedArtworkTrackID == track.id, let cached = cachedArtwork {
            return cached
        }
        cachedArtworkTrackID = track.id
        guard let data = track.artwork, let full = CoverExport.pixelSize(data) else {
            cachedArtwork = nil
            return nil
        }
        // The handler MUST be `@Sendable` — MediaPlayer stores the artwork in
        // the `nowPlayingInfo` dictionary and bridges it to NSDictionary, which
        // the system then enumerates on its own background queue. Without this
        // annotation, the closure inherits MainActor isolation from the
        // enclosing @MainActor class and crashes the Swift runtime's
        // `_swift_task_checkIsolatedSwift` assertion during that enumeration.
        // Capturing `Data` + `CGSize` (both Sendable) keeps the closure valid.
        //
        // Handed over at no more than 1000 px (decoded small, on the system's
        // queue when it asks), so a 4000 px cover doesn't cost a 64 MB bitmap.
        let scale = min(1, Double(CoverExport.maxPixel) / Double(max(full.width, full.height, 1)))
        let size = CGSize(width: Double(full.width) * scale, height: Double(full.height) * scale)
        let artwork = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            CoverExport.image(data) ?? NSImage(size: size)
        }
        cachedArtwork = artwork
        return artwork
    }
}
