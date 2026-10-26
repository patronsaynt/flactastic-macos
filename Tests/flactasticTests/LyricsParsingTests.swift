import Foundation
import Testing
@testable import flactastic

struct LyricsParsingTests {
    private func times(_ lyrics: Lyrics) -> [Double] {
        lyrics.lines.compactMap(\.timestamp).map { ($0 * 1000).rounded() / 1000 }
    }

    @Test func parsesStandardLRCLIBTimestamps() {
        let lyrics = Lyrics.parseLRC("[ar:x]\n[00:12.34] One\n[01:02.5]Two\n[02:03.456]Three")
        #expect(lyrics.isSynced)
        #expect(times(lyrics) == [12.34, 62.5, 123.456])
        #expect(lyrics.lines.map(\.text) == ["One", "Two", "Three"])
    }

    @Test func multiTimestampLinesAreSorted() {
        let lyrics = Lyrics.parseLRC("[00:30.00][00:10.00]Chorus\n[00:20.00]Verse")
        #expect(times(lyrics) == [10, 20, 30])
        #expect(lyrics.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
    }

    @Test func acceptsColonAndCommaFractionVariants() {
        let lyrics = Lyrics.parseLRC("[00:12:50]A\n[00:13,25]B")
        #expect(times(lyrics) == [12.5, 13.25])
    }

    @Test func positiveOffsetShowsLyricsSooner() {
        let lyrics = Lyrics.parseLRC("[offset:+500]\n[00:10.00]A\n[00:00.20]B")
        #expect(times(lyrics) == [0, 9.5])
    }

    @Test func negativeOffsetShowsLyricsLater() {
        let lyrics = Lyrics.parseLRC("[offset:-250]\n[00:10.00]A")
        #expect(times(lyrics) == [10.25])
    }

    @Test func plainTextIsNotSynced() {
        #expect(!Lyrics.fromPlainText("a\nb", duration: 100).isSynced)
    }
}
