@preconcurrency import AVFoundation

/// What the engine's read loop needs from a source of PCM. `AVAudioFile`
/// already is one; the server's streams (`Server/ServerStream.swift`) are
/// the others. Positions and lengths are in `processingFormat` frames.
protocol PCMSource: AnyObject {
    /// Where a server library's track is coming from; nil for a local file.
    var playbackSource: PlaybackSource? { get }
    var processingFormat: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    var framePosition: AVAudioFramePosition { get set }
    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws
}

extension PCMSource {
    var playbackSource: PlaybackSource? { nil }
}

extension AVAudioFile: PCMSource {}

/// What a server library's track is playing from, shown beside the
/// player's quality badge.
enum PlaybackSource: Equatable, Sendable {
    /// A verified offline copy on this Mac.
    case offline
    /// The original file, streamed.
    case streaming
    /// A transcode, streamed.
    case transcode(StreamQuality)
}

/// An offline copy of a server track: the file, marked as such.
final class OfflineCopySource: PCMSource {
    private let file: AVAudioFile
    init(_ file: AVAudioFile) { self.file = file }
    var playbackSource: PlaybackSource? { .offline }
    var processingFormat: AVAudioFormat { file.processingFormat }
    var length: AVAudioFramePosition { file.length }
    var framePosition: AVAudioFramePosition {
        get { file.framePosition }
        set { file.framePosition = newValue }
    }
    func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        try file.read(into: buffer, frameCount: frames)
    }
}
