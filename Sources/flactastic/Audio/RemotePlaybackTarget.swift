import Foundation

/// A device that plays the queue in place of the local audio graph — e.g. a
/// DLNA renderer that pulls each track over HTTP. While one is attached,
/// `PlayerEngine` keeps owning the queue, index, repeat and timing state, and
/// forwards transport intent here instead of decoding.
///
/// Every call is fire-and-forget: implementations serialize their own network
/// work and report back through `PlayerEngine.remoteDid…` methods.
@MainActor
protocol RemotePlaybackTarget: AnyObject {
    /// Replace what the device is playing with `track`, starting `startAt`
    /// seconds in, and pre-arm `next` for a gapless handoff.
    func load(_ track: Track, next: Track?, startAt: TimeInterval, autoplay: Bool)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    /// The track that should follow the current one, or nil at the end of the queue.
    func setNext(_ track: Track?)
    /// 0...1, applied to the device's own volume control.
    func setVolume(_ volume: Float)
}
