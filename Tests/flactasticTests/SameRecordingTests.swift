import Foundation
import Testing
@testable import flactastic

// A local file becomes the server track's copy only when it's provably the
// same recording: identical bytes, or a FLAC whose audio checksum and shape
// match. Anything else is left alone.

private let fixture = FixtureSupport.audioDir.appendingPathComponent("cur-acdc.flac")
private let metaflac = ["/opt/homebrew/bin/metaflac", "/usr/local/bin/metaflac"].first(where: FileManager.default.isExecutableFile)

private func info(md5 byte: UInt8 = 0xAB, samples: Int64 = 4410, rate: Int = 44_100, bits: Int = 16) -> FLACStreamInfo {
    FLACStreamInfo(sampleRate: rate, channels: 2, bitsPerSample: bits, totalSamples: samples, audioMD5: Data(repeating: byte, count: 16))
}

@Test("STREAMINFO reads as metaflac reports it")
func parsesRealFLAC() throws {
    let parsed = try #require(FLACStreamInfo.read(fileAt: fixture))
    #expect(parsed.sampleRate == 44_100)
    #expect(parsed.channels == 2)
    #expect(parsed.bitsPerSample == 16)
    #expect(parsed.totalSamples == 4410)
    #expect(parsed.audioMD5.map { String(format: "%02x", $0) }.joined() == "882c7029a5097769b85bd176f5752684")
}

@Test("An ID3 tag in front of the FLAC is skipped")
func skipsID3Prefix() throws {
    let flac = try Data(contentsOf: fixture)
    // A 20-byte ID3v2 tag: header with a syncsafe size of 10, then 10 bytes.
    let id3 = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 10]) + Data(repeating: 0, count: 10)
    #expect(FLACStreamInfo.parse(id3 + flac) == FLACStreamInfo.read(fileAt: fixture))
    #expect(FLACStreamInfo.parse(Data("not a flac".utf8)) == nil)
}

@Test("Retagging changes the bytes but not the recording", .enabled(if: metaflac != nil))
func retagKeepsAudio() throws {
    let dir = try FixtureSupport.makeTempDir("retag")
    let copy = dir.appendingPathComponent("copy.flac")
    try FileManager.default.copyItem(at: fixture, to: copy)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: metaflac!)
    p.arguments = ["--remove-all-tags", "--set-tag=TITLE=Something Else", copy.path]
    try p.run(); p.waitUntilExit()

    #expect(try ContentHasher.hexDigest(ofFileAt: copy) != ContentHasher.hexDigest(ofFileAt: fixture))
    let a = try #require(FLACStreamInfo.read(fileAt: copy)), b = try #require(FLACStreamInfo.read(fileAt: fixture))
    #expect(a.isSameAudio(as: b))
}

@Test("Identical bytes are a copy")
func verdictIdentical() {
    #expect(ServerUploads.verdict(ownHash: "h", serverHash: "h", mine: info(), theirs: info(md5: 1), serverFrames: nil) == .identical(hash: "h"))
}

@Test("Same audio in other bytes is the same recording")
func verdictSameAudio() {
    #expect(ServerUploads.verdict(ownHash: "mine", serverHash: "theirs", mine: info(), theirs: info(), serverFrames: 4410)
            == .sameAudio(ownHash: "mine", serverHash: "theirs"))
}

@Test("Different audio, an unset checksum, or a length the server disagrees with is left alone")
func verdictLeaveAlone() {
    #expect(ServerUploads.verdict(ownHash: "a", serverHash: "b", mine: info(), theirs: info(md5: 0xCD), serverFrames: nil) == .leaveAlone)
    #expect(ServerUploads.verdict(ownHash: "a", serverHash: "b", mine: info(bits: 24), theirs: info(bits: 16), serverFrames: nil) == .leaveAlone)
    #expect(ServerUploads.verdict(ownHash: "a", serverHash: "b", mine: info(md5: 0), theirs: info(md5: 0), serverFrames: nil) == .leaveAlone)
    #expect(ServerUploads.verdict(ownHash: "a", serverHash: "b", mine: info(), theirs: info(), serverFrames: 9999) == .leaveAlone)
}

@Test("A matched copy compares by the server's hash; older entries still load")
func installedMatchHash() throws {
    let old = #"{"relativePath":"a.flac","contentHash":"own","tagFingerprint":"t","fileSize":1,"format":"flac","kept":true}"#
    var copy = try JSONDecoder().decode(OfflineCopies.Installed.self, from: Data(old.utf8))
    #expect(copy.matchHash == "own")
    #expect(!copy.isUsersOwn)
    copy.audioMatch = "server"
    #expect(copy.matchHash == "server")
    #expect(copy.isUsersOwn)
}
