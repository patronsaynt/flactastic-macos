import Foundation
@testable import flactastic

/// Shared helpers for the tag fixtures under `Tests/Fixtures`. The folder sits
/// outside the test target (so SwiftPM doesn't bundle it), and is found from
/// this file's own path instead.
enum FixtureSupport {
    static let fixturesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // flactasticTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)

    static var audioDir: URL { fixturesDir.appendingPathComponent("audio", isDirectory: true) }
    static var baselineURL: URL { fixturesDir.appendingPathComponent("display-baseline.json") }

    static let flacPath = ["/opt/homebrew/bin/flac", "/usr/local/bin/flac"].first(where: FileManager.default.isExecutableFile)
    static let ffmpegPath = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile)

    static func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tenth of a second of 44.1k 16-bit stereo silence.
    static func writeSilentWAV(to url: URL) throws {
        var data = Data("RIFF".utf8)
        let samples = 4410 * 4
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        data += le32(36 + samples) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(44100) + le32(44100 * 4) + le16(4) + le16(16)
        data += Data("data".utf8) + le32(samples) + Data(count: samples)
        try data.write(to: url)
    }

    /// Encodes silence to `ext` ("flac", "mp3" or "m4a") with no tags.
    /// Returns nil when the encoder for that format isn't installed.
    static func makeSilentAudio(ext: String, in dir: URL, name: String = "tone") throws -> URL? {
        let wav = dir.appendingPathComponent("\(name)-src.wav")
        try writeSilentWAV(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let out = dir.appendingPathComponent("\(name).\(ext)")
        let process = Process()
        switch ext {
        case "flac":
            guard let flacPath else { return nil }
            process.executableURL = URL(fileURLWithPath: flacPath)
            process.arguments = ["-s", "-f", "-o", out.path, wav.path]
        case "mp3":
            guard let ffmpegPath else { return nil }
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-y", "-loglevel", "error", "-i", wav.path, "-map_metadata", "-1",
                                 "-codec:a", "libmp3lame", "-b:a", "64k", "-id3v2_version", "0",
                                 "-write_xing", "0", out.path]
        case "m4a":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "m4af", "-d", "aac", wav.path, out.path]
        default:
            return nil
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? out : nil
    }

    /// Copies every committed fixture into a fresh temp folder, so tests that
    /// write tags never touch the committed files.
    static func copyFixtures() throws -> URL {
        let dir = try makeTempDir("fixtures")
        let files = try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        return dir
    }

    /// Loads every audio file in `dir` the way a library scan does.
    static func scan(_ dir: URL) async throws -> [Track] {
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let scanner = LibraryScanner()
        var tracks: [Track] = []
        for url in urls {
            guard let stub = Track.makeFromURL(url) else { continue }
            tracks.append(await scanner.loadMetadata(for: stub))
        }
        return tracks
    }
}
