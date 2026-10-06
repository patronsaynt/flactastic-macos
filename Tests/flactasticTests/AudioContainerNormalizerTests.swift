import AVFoundation
import Foundation
import Testing
@testable import flactastic

// Tests for AudioContainerNormalizer — the step that turns SoundCloud's
// MP4-wrapped AAC (as Lucida delivers it) into an .m4a the library indexes.
// Fixtures are generated on the fly from a system sound so nothing binary
// lives in the repo.

private let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("normalizer-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "\(tool) failed")
}

/// AAC-in-MP4 with an `.mp4` name — the shape Lucida hands back for SoundCloud.
private func makeAACMP4(in dir: URL) throws -> URL {
    let out = dir.appendingPathComponent("track.mp4")
    try run("/usr/bin/afconvert", ["-f", "mp4f", "-d", "aac", "-b", "256000",
                                   "/System/Library/Sounds/Ping.aiff", out.path])
    return out
}

private func audioFormatIDs(_ url: URL) async throws -> [AudioFormatID] {
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    var ids: [AudioFormatID] = []
    for t in tracks {
        for d in try await t.load(.formatDescriptions) { ids.append(CMFormatDescriptionGetMediaSubType(d)) }
    }
    return ids
}

@Test("Non-container files pass through untouched")
func passesThroughNonContainers() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let flac = dir.appendingPathComponent("song.flac")
    try Data("not really flac".utf8).write(to: flac)

    let result = try await AudioContainerNormalizer.normalize(flac)
    #expect(result == flac)
    #expect(FileManager.default.fileExists(atPath: flac.path))
}

@Test("Audio-only AAC MP4 becomes an .m4a with identical bytes and the .mp4 is gone")
func renamesAudioOnlyAAC() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mp4 = try makeAACMP4(in: dir)
    let originalBytes = try Data(contentsOf: mp4)

    let result = try await AudioContainerNormalizer.normalize(mp4)
    #expect(result.pathExtension == "m4a")
    #expect(!FileManager.default.fileExists(atPath: mp4.path))
    #expect(try Data(contentsOf: result) == originalBytes)
    #expect(AudioFileFormat.classify(result) != nil)
}

@Test("MP4 with a video track becomes an audio-only AAC .m4a",
      .enabled(if: ffmpegPath != nil, "ffmpeg not installed"))
func extractsAudioFromVideoMP4() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mp4 = dir.appendingPathComponent("video.mp4")
    try run(ffmpegPath!, ["-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1",
                          "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                          "-c:v", "libx264", "-c:a", "aac", "-b:a", "256k",
                          "-shortest", mp4.path])

    let result = try await AudioContainerNormalizer.normalize(mp4)
    #expect(result.pathExtension == "m4a")
    #expect(!FileManager.default.fileExists(atPath: mp4.path))

    let asset = AVURLAsset(url: result)
    #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
    #expect(try await audioFormatIDs(result) == [kAudioFormatMPEG4AAC])
}

@Test("An MP4 with no audio track fails cleanly",
      .enabled(if: ffmpegPath != nil, "ffmpeg not installed"))
func rejectsSilentVideo() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mp4 = dir.appendingPathComponent("silent.mp4")
    try run(ffmpegPath!, ["-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1",
                          "-c:v", "libx264", mp4.path])

    await #expect(throws: AudioContainerNormalizer.NormalizeError.self) {
        try await AudioContainerNormalizer.normalize(mp4)
    }
}
