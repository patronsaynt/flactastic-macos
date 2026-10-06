import CoreAudioTypes
import Foundation
import Testing
@testable import flactastic

struct AudioFileFormatTests {
    @Test func m4aRefinesToActualCodec() {
        #expect(AudioFileFormat.refine(.alac, codec: kAudioFormatMPEG4AAC) == .aac)
        #expect(AudioFileFormat.refine(.alac, codec: kAudioFormatMPEG4AAC_HE) == .aac)
        #expect(AudioFileFormat.refine(.alac, codec: kAudioFormatAppleLossless) == .alac)
        #expect(AudioFileFormat.refine(.aac, codec: kAudioFormatAppleLossless) == .alac)
    }

    @Test func nonMP4FormatsAreNeverRefined() {
        #expect(AudioFileFormat.refine(.flac, codec: kAudioFormatMPEG4AAC) == nil)
        #expect(AudioFileFormat.refine(.mp3, codec: kAudioFormatAppleLossless) == nil)
    }

    @Test func movingAnAACFileKeepsItsCodec() {
        let m4a = URL(fileURLWithPath: "/x/y.m4a")
        #expect(AudioFileFormat.classify(m4a, keeping: .aac) == .aac)
        #expect(AudioFileFormat.classify(m4a, keeping: .alac) == .alac)
        #expect(AudioFileFormat.classify(URL(fileURLWithPath: "/x/y.flac"), keeping: .aac) == .flac)
        #expect(AudioFileFormat.classify(URL(fileURLWithPath: "/x/y.txt"), keeping: .aac) == .aac)
    }

    @Test func staleM4ACacheEntryForcesReparse() throws {
        let track = Track(url: URL(fileURLWithPath: "/x/y.m4a"), title: "t", fileFormat: .alac)
        var entry = TrackMetadataCacheEntry(track: track, fileSize: 1, mtime: Date())
        #expect(entry.hasFormat(forFileAt: track.url))
        entry.fileFormat = nil   // sidecar written before refinement existed
        #expect(!entry.hasFormat(forFileAt: track.url))
        #expect(entry.hasFormat(forFileAt: URL(fileURLWithPath: "/x/y.flac")))
    }
}
