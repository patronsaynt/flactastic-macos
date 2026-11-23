import Foundation

/// A FLAC's STREAMINFO block: the audio's shape and the MD5 of its decoded
/// samples, which tags, artwork and padding don't change. Two files with the
/// same STREAMINFO hold the same recording, sample for sample.
struct FLACStreamInfo: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let totalSamples: Int64
    /// MD5 of the unencoded audio; all zeros when the encoder didn't set it.
    let audioMD5: Data

    /// Same recording: every field equal and a real checksum on both sides.
    func isSameAudio(as other: FLACStreamInfo) -> Bool {
        audioMD5.contains { $0 != 0 } && self == other
    }

    /// Parses STREAMINFO from the start of a FLAC file. An ID3v2 tag in front
    /// (some taggers add one) is skipped when the bytes reach past it.
    static func parse(_ bytes: Data) -> FLACStreamInfo? {
        let b = [UInt8](bytes)
        var start = 0
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {   // "ID3"
            let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
            start = 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0)
        }
        // "fLaC", then a block header whose type (low 7 bits) is 0, length 34.
        guard b.count >= start + 42,
              b[start] == 0x66, b[start + 1] == 0x4C, b[start + 2] == 0x61, b[start + 3] == 0x43,
              b[start + 4] & 0x7F == 0,
              (Int(b[start + 5]) << 16 | Int(b[start + 6]) << 8 | Int(b[start + 7])) == 34 else { return nil }
        let info = start + 8
        var packed: UInt64 = 0
        for i in 10..<18 { packed = packed << 8 | UInt64(b[info + i]) }
        return FLACStreamInfo(
            sampleRate: Int(packed >> 44),
            channels: Int((packed >> 41) & 0x7) + 1,
            bitsPerSample: Int((packed >> 36) & 0x1F) + 1,
            totalSamples: Int64(packed & 0xF_FFFF_FFFF),
            audioMD5: Data(b[(info + 18)..<(info + 34)])
        )
    }

    /// How many bytes from the start of a file to read for `parse`.
    static let headerBytes = 16 * 1024

    static func read(fileAt url: URL) -> FLACStreamInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: headerBytes)).flatMap(parse)
    }
}
