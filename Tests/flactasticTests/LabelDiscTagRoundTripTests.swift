import Foundation
import Testing
@testable import flactastic

// Writes LABEL and the disc tags with MetadataWriter and reads them back with
// LibraryScanner, on real encoded files: FLAC keeps the total in
// DISCTOTAL, MP4 packs "n/t" into its disk atom. Skipped when no encoder is
// available.

private func makeAudioFile(format: String, ext: String) throws -> URL? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tagtrip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wav = dir.appendingPathComponent("tone.wav")
    // A tenth of a second of silence: 44.1k, 16-bit, stereo.
    var data = Data("RIFF".utf8)
    let samples = 4410 * 4
    func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    data += le32(36 + samples) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(44100) + le32(44100 * 4) + le16(4) + le16(16)
    data += Data("data".utf8) + le32(samples) + Data(count: samples)
    try data.write(to: wav)
    let out = dir.appendingPathComponent("tone.\(ext)")
    let process = Process()
    if ext == "flac" {
        // afconvert's FLAC encoder writes a stub with no stream header; use
        // the reference encoder when it's installed, and skip otherwise.
        guard let flac = ["/opt/homebrew/bin/flac", "/usr/local/bin/flac"].first(where: FileManager.default.isExecutableFile) else { return nil }
        process.executableURL = URL(fileURLWithPath: flac)
        process.arguments = ["-s", "-f", "-o", out.path, wav.path]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", format, wav.path, out.path]
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? out : nil
}

private func roundTrip(format: String, ext: String, fileFormat: AudioFileFormat) async throws {
    guard let url = try makeAudioFile(format: format, ext: ext) else { return }
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let track = Track(url: url, title: "Tone", fileFormat: fileFormat)
    let writer = MetadataWriter()
    _ = try await writer.write(to: track, title: "Tone", artist: nil, album: "Box", year: 1993, genre: nil, trackNumber: 1,
                               labelChange: .set("Sub Pop"), discChange: .set(number: 2, total: 3))
    let read = await LibraryScanner().loadMetadata(for: track)
    #expect(read.label == "Sub Pop")
    #expect(read.discNumber == 2)
    #expect(read.discTotal == 3)

    _ = try await writer.write(to: read, title: "Tone", artist: nil, album: "Box", year: 1993, genre: nil, trackNumber: 1,
                               labelChange: .set(nil), discChange: .set(number: nil, total: nil))
    let cleared = await LibraryScanner().loadMetadata(for: track)
    #expect(cleared.label == nil)
    #expect(cleared.discNumber == nil)
    #expect(cleared.discTotal == nil)
}

@Test func labelAndDiscTagsRoundTripInFLAC() async throws {
    try await roundTrip(format: "flac", ext: "flac", fileFormat: .flac)
}

@Test func labelAndDiscTagsRoundTripInMP4() async throws {
    try await roundTrip(format: "alac", ext: "m4a", fileFormat: .alac)
}
