import AppKit
import Foundation
import Testing
@testable import flactastic

/// Covers keep their full resolution: nothing between choosing a 4000 px
/// image and reading it back out of the file shrinks it.
struct CoverResolutionTests {
    private func jpeg(side: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        return try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }

    private func audioFile() throws -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("tone.wav")
        var data = Data("RIFF".utf8)
        let samples = 4410 * 4
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        data += le32(36 + samples) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(44100) + le32(44100 * 4) + le16(4) + le16(16)
        data += Data("data".utf8) + le32(samples) + Data(count: samples)
        try data.write(to: wav)
        let out = dir.appendingPathComponent("tone.m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "alac", wav.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    @Test func a4000pxCoverIsStoredAndReadBackAt4000px() async throws {
        let url = try #require(try audioFile())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cover = try jpeg(side: 4000)
        let track = Track(url: url, title: "Tone", fileFormat: .alac)
        _ = try await MetadataWriter().write(to: track, title: "Tone", artist: nil, album: "A", year: nil, genre: nil,
                                             trackNumber: 1, artworkChange: .updated(cover))
        let read = await LibraryScanner().loadMetadata(for: track)
        let stored = try #require(read.artwork)
        #expect(stored == cover)
        let info = try #require(CoverInfo(stored))
        #expect(info.width == 4000 && info.height == 4000)
    }

    @Test func untouchedCropMeansTheWholeImage() {
        let size = CGSize(width: 4000, height: 4000)
        #expect(ImageCropperView.coversWholeImage(CGRect(x: 0, y: 1, width: 4000, height: 3999), size))
        #expect(!ImageCropperView.coversWholeImage(CGRect(x: 400, y: 400, width: 3200, height: 3200), size))
    }

    @Test func coverFormatFromBytes() throws {
        #expect(CoverFormat(try jpeg(side: 8)) == .jpeg)
        #expect(CoverFormat(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == .png)
        #expect(CoverFormat(Data("....ftypheic".utf8)) == .other)
    }
}

/// Covers leaving the app (Now Playing, cast devices) go at 1000 px or less.
struct CoverExportTests {
    private func image(side: Int, png: Bool) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        return try #require(rep.representation(using: png ? .png : .jpeg, properties: [:]))
    }

    @Test func bigCoversShrinkToA1000pxJPEG() throws {
        for png in [false, true] {
            let out = try #require(CoverExport.jpeg(try image(side: 4000, png: png)))
            #expect(CoverFormat(out) == .jpeg)
            let size = try #require(CoverExport.pixelSize(out))
            #expect(size.width == 1000 && size.height == 1000)
        }
    }

    @Test func smallJPEGsPassThroughAndSmallPNGsBecomeJPEG() throws {
        let small = try image(side: 600, png: false)
        #expect(CoverExport.jpeg(small) == small)
        let png = try image(side: 600, png: true)
        let out = try #require(CoverExport.jpeg(png))
        #expect(CoverFormat(out) == .jpeg)
        #expect(CoverExport.pixelSize(out)?.width == 600)
    }

    @Test func nowPlayingImageIsSmall() throws {
        let img = try #require(CoverExport.image(try image(side: 4000, png: false)))
        #expect(img.size.width == 1000)
    }
}
