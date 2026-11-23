import AVFoundation
import Foundation
import Testing
@testable import flactastic

/// A server track with a verified offline copy plays that copy, marked as
/// offline, whether or not the server connection is set up yet.
@Test("An offline copy plays as offline even with no server connection")
func offlineCopyPlaysWithoutClient() async throws {
    let dir = try FixtureSupport.makeTempDir("offline-copy")
    let url = dir.appendingPathComponent("tone.wav")
    try FixtureSupport.writeSilentWAV(to: url)
    let track = Track(url: url, title: "Tone", fileFormat: .wav)
    let id = UUID()

    let streamer = ServerStreamer()
    streamer.config.withLock {
        $0.client = nil
        $0.tracks[url.standardizedFileURL.path] = ServerStreamer.TrackInfo(
            id: id, format: .wav, fileSize: 0, contentHash: "h", sampleRate: 44_100, bitrate: 0, frames: nil)
        $0.offline = [id]
    }

    let source = try await streamer.open(track, at: 0)
    #expect(source?.playbackSource == .offline)
}
