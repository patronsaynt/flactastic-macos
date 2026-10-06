import Foundation
import Testing
@testable import flactastic

// MARK: - Helpers

private let cal = Calendar.current
/// A fixed midday "now" so day arithmetic never straddles midnight.
private let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!

private func track(album: String, artist: String = "Artist", genre: String? = nil) -> Track {
    Track(
        url: URL(fileURLWithPath: "/tmp/\(album).flac"),
        title: "Song", artist: artist, album: album,
        fileFormat: .flac, genre: genre
    )
}

private func date(years: Int = 0, days: Int = 0, hour: Int = 12, minute: Int = 0) -> Date {
    let base = cal.date(byAdding: DateComponents(year: -years, day: days), to: cal.startOfDay(for: now))!
    return cal.date(byAdding: DateComponents(hour: hour, minute: minute), to: base)!
}

@MainActor
private func store(_ plays: [(Track, Date, Double)]) -> ListeningStore {
    let store = ListeningStore()
    for (t, d, seconds) in plays {
        store.record(track: t, startedAt: d, secondsListened: seconds, counted: true)
    }
    return store
}

// MARK: - On this day

@Test @MainActor func onThisDayPrefersExactlyOneYearAgo() {
    let s = store([
        (track(album: "Vespertine"), date(years: 1), 240),
        (track(album: "Homogenic"), date(years: 2), 240),
        (track(album: "Homogenic"), date(years: 2), 240),
    ])
    let pick = s.onThisDay(now: now) { _ in true }
    #expect(pick?.album == "Vespertine")
    #expect(pick?.headline == "A year ago today you played")
}

@Test @MainActor func onThisDayFallsBackToEarlierYears() {
    let s = store([
        (track(album: "Debut"), date(years: 3), 240),
        (track(album: "Post"), date(years: 2), 240),
    ])
    let pick = s.onThisDay(now: now) { _ in true }
    #expect(pick?.album == "Post")
    #expect(pick?.headline == "2 years ago today you played")
}

@Test @MainActor func onThisDayFallsBackToWeekLastYear() {
    let s = store([
        (track(album: "Medúlla"), date(years: 1, days: 2), 240),
        (track(album: "Volta"), date(years: 1, days: 5), 240),
    ])
    let pick = s.onThisDay(now: now) { _ in true }
    #expect(pick?.album == "Medúlla")
    #expect(pick?.headline == "This week last year you played")
}

@Test @MainActor func onThisDayPicksMostPlaysThenMinutes() {
    let s = store([
        (track(album: "A"), date(years: 1, hour: 9), 200),
        (track(album: "B"), date(years: 1, hour: 10), 100),
        (track(album: "B"), date(years: 1, hour: 11), 100),
        (track(album: "C"), date(years: 1, hour: 13), 300),
        (track(album: "C"), date(years: 1, hour: 14), 300),
    ])
    let pick = s.onThisDay(now: now) { _ in true }
    #expect(pick?.album == "C")
    #expect(pick?.plays == 2)
}

@Test @MainActor func onThisDaySkipsAlbumsNoLongerInLibrary() {
    let s = store([(track(album: "Gone"), date(years: 1), 240)])
    #expect(s.onThisDay(now: now) { _ in false } == nil)
}

@Test @MainActor func onThisDayHidesWhenNothingMatches() {
    let s = store([(track(album: "Recent"), date(days: -2), 240)])
    #expect(s.onThisDay(now: now) { _ in true } == nil)
}

// MARK: - Hourly genre breakdown

@Test @MainActor func hourlySplitsListensAcrossHourBoundaries() {
    // 20 minutes starting at 9:50 → 10 in hour 9, 10 in hour 10.
    let s = store([(track(album: "X", genre: "Jazz"), date(hour: 9, minute: 50), 20 * 60)])
    let b = s.hourlyGenreMinutes(now: now)
    #expect(b.series.map(\.name) == ["Jazz"])
    #expect(abs(b.buckets[9][0] - 10) < 0.001)
    #expect(abs(b.buckets[10][0] - 10) < 0.001)
}

@Test @MainActor func hourlyKeepsTopThreeGenresAndFoldsTheRestIntoOther() {
    let s = store([
        (track(album: "1", genre: "Electronic"), date(hour: 8), 40 * 60),
        (track(album: "2", genre: "Jazz"), date(hour: 9), 30 * 60),
        (track(album: "3", genre: "Rock"), date(hour: 10), 20 * 60),
        (track(album: "4", genre: "Folk"), date(hour: 11), 10 * 60),
        (track(album: "5"), date(hour: 12), 5 * 60),
        (track(album: "6", genre: "Rock"), date(days: -1, hour: 12), 60 * 60),
    ])
    let b = s.hourlyGenreMinutes(now: now)
    #expect(b.series.map(\.name) == ["Electronic", "Jazz", "Rock", "Other"])
    #expect(abs(b.series[3].minutes - 15) < 0.001)
    #expect(abs(b.buckets[11][3] - 10) < 0.001)
}

@Test @MainActor func dailyCoversSevenDaysEndingOnGivenDay() {
    let s = store([
        (track(album: "1", genre: "Jazz"), date(days: 0, hour: 9), 30 * 60),
        (track(album: "2", genre: "Jazz"), date(days: -6, hour: 9), 20 * 60),
        (track(album: "3", genre: "Jazz"), date(days: -7, hour: 9), 99 * 60),   // outside
    ])
    let b = s.dailyGenreMinutes(endingOn: now)
    #expect(b.starts.count == 7)
    #expect(b.starts.last == cal.startOfDay(for: now))
    #expect(abs(b.buckets[6][0] - 30) < 0.001)
    #expect(abs(b.buckets[0][0] - 20) < 0.001)
    #expect(abs(b.series[0].minutes - 50) < 0.001)
}

@Test @MainActor func dailySplitsListensAcrossMidnight() {
    // 30 minutes starting at 11:45 PM yesterday → 15 yesterday, 15 today.
    let s = store([(track(album: "X", genre: "Rock"), date(days: -1, hour: 23, minute: 45), 30 * 60)])
    let b = s.dailyGenreMinutes(endingOn: now)
    #expect(abs(b.buckets[5][0] - 15) < 0.001)
    #expect(abs(b.buckets[6][0] - 15) < 0.001)
}
