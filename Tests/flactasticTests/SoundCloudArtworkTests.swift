import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import flactastic

// Tests for SoundCloudArtwork — upgrading Lucida's thumbnail-sized SoundCloud
// cover URLs to the original upload, delivered as JPEG.

@Test("Thumbnail URLs map to original and fixed-size renditions")
func soundCloudCandidates() throws {
    let url = URL(string: "https://i1.sndcdn.com/artworks-000067273316-smsiqx-large.jpg")!
    let c = try #require(SoundCloudArtwork.candidates(for: url))
    #expect(c.originals.map(\.absoluteString) == [
        "https://i1.sndcdn.com/artworks-000067273316-smsiqx-original.jpg",
        "https://i1.sndcdn.com/artworks-000067273316-smsiqx-original.png",
    ])
    #expect(c.fixed.first?.absoluteString
            == "https://i1.sndcdn.com/artworks-000067273316-smsiqx-t3000x3000.jpg")
}

@Test("Newer artwork ids with extra hyphens keep their full stem")
func soundCloudCandidatesNewIDs() throws {
    let url = URL(string: "https://i1.sndcdn.com/artworks-AbC123xYz-0-t500x500.png")!
    let c = try #require(SoundCloudArtwork.candidates(for: url))
    #expect(c.originals.first?.lastPathComponent == "artworks-AbC123xYz-0-original.jpg")
}

@Test("Non-SoundCloud artwork is left alone")
func soundCloudIgnoresOtherHosts() {
    #expect(!SoundCloudArtwork.isArtworkURL(URL(string: "https://resources.tidal.com/images/a/b/c/1280x1280.jpg")!))
    #expect(!SoundCloudArtwork.isArtworkURL(URL(string: "https://i1.sndcdn.com/something-else.jpg")!))
}

private func makeImage(width: Int, height: Int, type: UTType) throws -> Data {
    let ctx = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(ctx.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func describe(_ data: Data) throws -> (type: String, width: Int) {
    let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    return (CGImageSourceGetType(src)! as String, props[kCGImagePropertyPixelWidth] as! Int)
}

@Test("A JPEG within the size cap is returned byte-for-byte")
func jpegPassesThrough() throws {
    let jpeg = try makeImage(width: 600, height: 600, type: .jpeg)
    #expect(SoundCloudArtwork.jpegData(from: jpeg) == jpeg)
}

@Test("A PNG original is re-encoded as JPEG at its native size")
func pngBecomesJPEG() throws {
    let png = try makeImage(width: 800, height: 800, type: .png)
    let out = try #require(SoundCloudArtwork.jpegData(from: png))
    let info = try describe(out)
    #expect(info.type == UTType.jpeg.identifier)
    #expect(info.width == 800)
}

@Test("An oversized original is scaled down to the cap")
func oversizedIsCapped() throws {
    let jpeg = try makeImage(width: 400, height: 200, type: .jpeg)
    let out = try #require(SoundCloudArtwork.jpegData(from: jpeg, maxPixelSize: 100))
    #expect(try describe(out).width == 100)
}

@Test("Non-image data is rejected")
func garbageIsRejected() {
    #expect(SoundCloudArtwork.jpegData(from: Data("<html>404</html>".utf8)) == nil)
}
