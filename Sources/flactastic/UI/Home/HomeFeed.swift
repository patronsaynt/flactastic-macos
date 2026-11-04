import Foundation

/// Home's sections below the top, in their designed order. People can
/// switch "Arrange Automatically" off in Settings to hide or reorder them;
/// a section with nothing to show stays hidden either way.
enum HomeSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case recommended, recentlyPlayed, jumpBackIn, onRepeat, mixes, timeOfDay, recentlyAdded, listening, bestSounding, fidelidex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: "Recommended for today"
        case .recentlyPlayed: "Recently played"
        case .jumpBackIn: "Jump back in"
        case .onRepeat: "On repeat"
        case .mixes: "Mixes from your library"
        case .timeOfDay: "Time-of-day picks"
        case .recentlyAdded: "Recently added"
        case .listening: "Your listening"
        case .bestSounding: "Best sounding"
        case .fidelidex: "Fidelidex"
        }
    }

    var detail: String {
        switch self {
        case .recommended: "A fresh rotation each day"
        case .recentlyPlayed: "Albums and playlists you played last"
        case .jumpBackIn: "Favourites you haven't played lately"
        case .onRepeat: "Most-played tracks, last 30 days"
        case .mixes: "Playable mixes by genre, and radios for your top artists"
        case .timeOfDay: "What you tend to play at this hour"
        case .recentlyAdded: "New in your library"
        case .listening: "Time, streak, genres, top artists and albums"
        case .bestSounding: "Your highest-fidelity albums"
        case .fidelidex: "Fidelity across your library"
        }
    }
}

/// Today's recommendations, kept for the whole day: picked once each
/// morning and saved, so listening during the day doesn't reshuffle them.
struct TodayRotation: Codable, Equatable {
    var day: String
    var lead: String
    var why: String
    var albums: [String]
}

/// Everything the shelves below the top show, built in one pass from the
/// library and listening history whenever either changes.
struct HomeFeed {
    struct AlbumPick: Identifiable {
        let album: Album
        /// Shown after the artist, e.g. "3 months" or "Yesterday".
        var note: String? = nil
        /// The note is a highlight (time since, now playing) rather than detail.
        var noteIsAccent = false
        var id: String { album.id }
    }

    struct RecentPick: Identifiable {
        let item: RecentItem
        let when: String
        var id: String { item.id }
    }

    struct Today {
        let lead: Album
        let why: String
        let albums: [Album]
    }

    struct Mix: Identifiable {
        let id: String
        let name: String
        let hue: Int
        /// The artist whose picture is the cover.
        let leadArtist: String
        let artists: [String]
        let tracks: [Track]
        /// The day this version was built ("2026-11-04").
        var day: String = ""
        /// Times this mix has been rerolled today.
        var rerolls: Int = 0
        /// This version of the mix: `id` stays the same day to day (it's what
        /// ratings are remembered under); this names one day's tracks, and
        /// each reroll's, for playback and for saving as a playlist.
        var editionID: String { "\(id)@\(day)" + (rerolls > 0 ? "#\(rerolls)" : "") }
        /// "Featuring A, B and C".
        var featuring: String {
            "Featuring " + ListFormatter.localizedString(byJoining: artists)
        }
    }

    struct RepeatTrack: Identifiable {
        let track: Track
        let plays: Int
        var id: UUID { track.id }
    }

    struct BestPick: Identifiable {
        let album: Album
        let bits: Int
        let rate: Double
        let quality: AudioQuality
        var id: String { album.id }
    }

    var today: Today?
    var rotation: TodayRotation?
    var recent: [RecentPick] = []
    var jumpBackIn: [AlbumPick] = []
    var onRepeat: [RepeatTrack] = []
    var mixes: [Mix] = []
    var timeOfDayTitle = ""
    var timeOfDaySubtitle = ""
    var timeOfDay: [AlbumPick] = []
    var recentlyAdded: [AlbumPick] = []
    var bestSounding: [BestPick] = []

    /// Hues for mix covers, laid over the artist's photo.
    static let mixHues: [(r: Double, g: Double, b: Double)] = [
        (1.0, 0.36, 0.17), (0.48, 0.42, 1.0), (1.0, 0.25, 0.69), (0.25, 0.66, 1.0),
        (0.13, 0.78, 0.6), (0.77, 0.6, 0.42), (0.94, 0.27, 0.27), (0.08, 0.72, 0.78),
    ]
}

// MARK: - Building

extension HomeFeed {
    struct Inputs {
        let albums: [Album]
        let tracks: [Track]
        let events: [PlayEvent]
        let recentContexts: [RecentContext]
        let onThisDay: OnThisDayPick?
        let storedRotation: TodayRotation?
        let resolver: ArtistResolver
        var now: Date = .now
        /// False while the library is still loading its tags: albums aren't
        /// grouped for good yet, so the day's picks wait rather than being
        /// rolled from half a library.
        var isLibraryLoaded = true
        /// Related artists, sound fingerprints and your mix feedback.
        var signals: MixCurator.Signals = .empty
    }

    private struct AlbumStats {
        var plays = 0
        var last: Date?
        var bands = [0, 0, 0, 0]
    }

    static func build(_ input: Inputs) -> HomeFeed {
        var feed = HomeFeed()
        let cal = Calendar.current
        let now = input.now
        let albumsByID = Dictionary(input.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracksByID = Dictionary(input.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Per-album play counts, last play and time-of-day spread.
        var stats: [String: AlbumStats] = [:]
        for e in input.events where e.counted {
            guard let id = e.albumID else { continue }
            var s = stats[id, default: AlbumStats()]
            s.plays += 1
            if s.last.map({ e.date > $0 }) ?? true { s.last = e.date }
            s.bands[band(cal.component(.hour, from: e.date))] += 1
            stats[id] = s
        }

        var rng = SeededRandom(seed: dayNumber(now, cal))

        feed.recent = recentPicks(input.recentContexts, now: now, cal: cal)
        (feed.today, feed.rotation) = today(input, albumsByID: albumsByID, stats: stats, now: now, rng: &rng)
        feed.jumpBackIn = jumpBackIn(input.albums, stats: stats, now: now)
        feed.onRepeat = onRepeat(input.events, tracks: tracksByID, now: now)
        feed.mixes = mixes(input, now: now, rng: &rng)
        let current = band(cal.component(.hour, from: now))
        (feed.timeOfDayTitle, feed.timeOfDaySubtitle) = bandNames[current]
        feed.timeOfDay = input.albums
            .compactMap { a -> (Album, Int)? in
                let n = stats[a.id]?.bands[current] ?? 0
                return n >= 2 ? (a, n) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(16)
            .map { AlbumPick(album: $0.0) }
        if feed.timeOfDay.count < 4 { feed.timeOfDay = [] }
        feed.recentlyAdded = recentlyAdded(input.albums, now: now, cal: cal)
        feed.bestSounding = bestSounding(input.albums, stats: stats)
        return feed
    }

    // MARK: Recently played

    private static func recentPicks(_ contexts: [RecentContext], now: Date, cal: Calendar) -> [RecentPick] {
        contexts.sorted { $0.date > $1.date }.prefix(16).map { c in
            RecentPick(item: RecentItem(kind: c.kind, targetID: c.targetID, title: c.title, subtitle: c.subtitle),
                       when: relativeDay(c.date, now: now, cal: cal))
        }
    }

    // MARK: Recommended for today

    /// The day's lead pick and rotation. On This Day leads when it finds an
    /// album; otherwise a favourite you've drifted from, or something barely
    /// played. The rest mixes favourites with albums you rarely reach for.
    private static func today(_ input: Inputs, albumsByID: [String: Album], stats: [String: AlbumStats],
                              now: Date, rng: inout SeededRandom) -> (Today?, TodayRotation?) {
        let day = dayKey(now)
        if let stored = input.storedRotation, stored.day == day, let lead = albumsByID[stored.lead] {
            let albums = stored.albums.compactMap { albumsByID[$0] }
            return (Today(lead: lead, why: stored.why, albums: albums), stored)
        }
        // Today's picks are rolled once, from the whole library.
        guard input.isLibraryLoaded else { return (nil, nil) }
        let playable = input.albums.filter { $0.tracks.count >= 2 }
        guard !playable.isEmpty else { return (nil, nil) }

        func since(_ a: Album) -> TimeInterval { stats[a.id]?.last.map { now.timeIntervalSince($0) } ?? .infinity }
        let favourites = playable.filter { (stats[$0.id]?.plays ?? 0) >= 3 }
            .sorted { (stats[$0.id]?.plays ?? 0) > (stats[$1.id]?.plays ?? 0) }
        let rarely = playable.filter { (stats[$0.id]?.plays ?? 0) <= 1 }

        var lead: Album
        var why: String
        if let pick = input.onThisDay, let album = albumsByID[pick.albumID] {
            lead = album
            why = "\(pick.headline) this \(pick.plays) time\(pick.plays == 1 ? "" : "s")."
        } else if let drifted = favourites.filter({ since($0) > 21 * 86_400 }).prefix(12).randomElement(using: &rng) {
            lead = drifted
            let plays = stats[drifted.id]?.plays ?? 0
            why = "You've played this \(plays) times. It's been \(ago(since(drifted)))."
        } else {
            lead = (rarely.randomElement(using: &rng) ?? playable.randomElement(using: &rng))!
            let plays = stats[lead.id]?.plays ?? 0
            why = plays == 0 ? "In your library, and still waiting for its first play." : "You've only played this once."
        }

        // Favourites not played this week, then rarely played, then anything.
        var pool = favourites.filter { $0.id != lead.id && since($0) > 7 * 86_400 }.prefix(30).shuffled(using: &rng).prefix(7)
        pool += rarely.filter { $0.id != lead.id }.shuffled(using: &rng).prefix(12 - pool.count)
        if pool.count < 12 {
            let taken = Set(pool.map(\.id) + [lead.id])
            pool += playable.filter { !taken.contains($0.id) }.shuffled(using: &rng).prefix(12 - pool.count)
        }
        let albums = Array(pool).shuffled(using: &rng)
        let rotation = TodayRotation(day: day, lead: lead.id, why: why, albums: albums.map(\.id))
        return (Today(lead: lead, why: why, albums: albums), rotation)
    }

    // MARK: Jump back in

    private static func jumpBackIn(_ albums: [Album], stats: [String: AlbumStats], now: Date) -> [AlbumPick] {
        albums.compactMap { a -> (Album, Int, TimeInterval)? in
            guard let s = stats[a.id], s.plays >= 4, let last = s.last else { return nil }
            let gap = now.timeIntervalSince(last)
            return gap > 30 * 86_400 ? (a, s.plays, gap) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(20)
        .map { AlbumPick(album: $0.0, note: ago($0.2), noteIsAccent: true) }
    }

    // MARK: On repeat

    private static func onRepeat(_ events: [PlayEvent], tracks: [UUID: Track], now: Date) -> [RepeatTrack] {
        let since = now.addingTimeInterval(-30 * 86_400)
        var counts: [UUID: Int] = [:]
        for e in events where e.counted && e.date >= since { counts[e.trackID, default: 0] += 1 }
        return counts.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .compactMap { id, n in tracks[id].map { RepeatTrack(track: $0, plays: n) } }
            .prefix(10)
            .map { $0 }
    }

    // MARK: Mixes

    /// Up to four genre mixes, from the genres you listen to most (or that
    /// fill most of the library before there's history), then a radio for up
    /// to two artists on heavy rotation: their tracks among the artists
    /// closest to them. Tracks are chosen by `MixCurator`, by how well they
    /// fit each mix rather than by sharing a genre tag alone.
    /// Mix Compilations (the tag set in the metadata editors) are left out,
    /// whole albums of them: cut to blend into their neighbours, they start
    /// and end mid-mix when shuffled into a playlist.
    private static func mixes(_ input: Inputs, now: Date, rng: inout SeededRandom) -> [Mix] {
        let day = dayKey(now)
        // Built once a day: after that, today's are shown as they were made
        // (edited only by ratings), so plays don't reshuffle them.
        if let today = input.signals.today, today.day == day {
            let byPath = Dictionary(input.tracks.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
            return today.mixes.compactMap { s in
                let tracks = s.paths.compactMap { byPath[$0] }
                guard !tracks.isEmpty else { return nil }
                return Mix(id: s.id, name: s.name, hue: s.hue, leadArtist: s.leadArtist,
                           artists: s.artists, tracks: tracks, day: day, rerolls: s.rerolls ?? 0)
            }
        }
        return distinctNames(generateMixes(input, now: now, rng: &rng)).map {
            var m = $0; m.day = day; return m
        }
    }

    /// A fresh draw of one mix: the same rules and ratings, a different roll
    /// of the dice. Nil if the mix can't be built from the library any more.
    static func reroll(_ mixID: String, times: Int, _ input: Inputs) -> Mix? {
        let now = input.now
        let day = dayKey(now)
        var rng = SeededRandom(seed: dayNumber(now, .current) &+ UInt64(abs(mixID.hashValueStable)) &+ UInt64(times) &* 0x9E37_79B9)
        var input = input
        input.signals.today = nil
        guard var mix = distinctNames(generateMixes(input, now: now, rng: &rng)).first(where: { $0.id == mixID }) else { return nil }
        mix.day = day
        mix.rerolls = times
        return mix
    }

    /// Two mixes with one name get their lead artist added: "Hardcore Mix · Angerfist".
    private static func distinctNames(_ mixes: [Mix]) -> [Mix] {
        var counts: [String: Int] = [:]
        for m in mixes { counts[m.name, default: 0] += 1 }
        return mixes.map { m in
            guard counts[m.name, default: 0] > 1 else { return m }
            return Mix(id: m.id, name: "\(m.name) · \(m.leadArtist)", hue: m.hue, leadArtist: m.leadArtist,
                       artists: m.artists, tracks: m.tracks, day: m.day)
        }
    }

    private static func generateMixes(_ input: Inputs, now: Date, rng: inout SeededRandom) -> [Mix] {
        let resolver = input.resolver
        let pool = mixPool(tracks: input.tracks, albums: input.albums)
        func credit(_ t: Track) -> String? { t.albumArtist ?? t.artist }

        var byGenre: [String: [Track]] = [:]
        var display: [String: String] = [:]
        for t in pool {
            for g in ([t.genre].compactMap { $0 } + t.secondaryGenres) {
                let name = g.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                byGenre[name.lowercased(), default: []].append(t)
                if display[name.lowercased()] == nil { display[name.lowercased()] = name }
            }
        }

        let recent = now.addingTimeInterval(-90 * 86_400)
        var genreMinutes: [String: Double] = [:]
        var artistMinutes: [String: Double] = [:]
        var artistPlays30: [String: Int] = [:]
        for e in input.events where e.date >= recent {
            if let g = e.genre?.lowercased() { genreMinutes[g, default: 0] += e.secondsListened / 60 }
            if let a = e.artist, let key = resolver.keys(forCredit: a).first {
                artistMinutes[key, default: 0] += e.secondsListened / 60
                if e.counted && e.date >= now.addingTimeInterval(-30 * 86_400) { artistPlays30[key, default: 0] += 1 }
            }
        }

        let curator = MixCurator(resolver: resolver, signals: input.signals, events: input.events,
                                 tracks: pool, artistMinutes: artistMinutes)

        let ranked = byGenre.keys.filter { (byGenre[$0]?.count ?? 0) >= 12 && $0 != "other" && $0 != "unknown" }
            .sorted { (genreMinutes[$0] ?? 0, byGenre[$0]?.count ?? 0) > (genreMinutes[$1] ?? 0, byGenre[$1]?.count ?? 0) }

        var mixes: [Mix] = []
        var usedHues = Set<Int>()
        func hue(for name: String) -> Int {
            var h = abs(name.hashValueStable) % mixHues.count
            while usedHues.contains(h) && usedHues.count < mixHues.count { h = (h + 1) % mixHues.count }
            usedHues.insert(h)
            return h
        }
        let byPath = Dictionary(pool.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        func artistsByWeight(_ tracks: [Track]) -> [String] {
            var weight: [String: Double] = [:]
            var shown: [String: String] = [:]
            for t in tracks {
                guard let c = credit(t), let key = resolver.keys(forCredit: c).first else { continue }
                weight[key, default: 0] += 1 + (artistMinutes[key] ?? 0)
                if shown[key] == nil { shown[key] = resolver.split(c).first ?? c }
            }
            return weight.sorted { $0.value > $1.value }.compactMap { shown[$0.key] }
        }

        for g in ranked.prefix(4) {
            let id = "genre:\(g)"
            let candidates = byGenre[g] ?? []
            // "More like this" seeds join the candidates even from other genres.
            let seeds = (input.signals.seeds[id] ?? []).suffix(5)
            let seedTracks = seeds.compactMap { byPath[$0] }
            let core = curator.core(of: candidates, seedPaths: Array(seeds))
            var extra: [Track] = []
            for s in seedTracks { extra += curator.similar(to: s, in: pool, count: 8) }
            var seen = Set<String>()
            let all = (candidates + extra).filter { seen.insert($0.url.path).inserted }
            let tracks = curator.pick(all, core: core, mixID: id, count: 50, rng: &rng)
            guard tracks.count >= 8 else { continue }
            let artists = artistsByWeight(tracks)
            guard let lead = artists.first else { continue }
            let name = (display[g] ?? g.capitalized) + " Mix"
            mixes.append(Mix(id: id, name: name, hue: hue(for: name), leadArtist: lead,
                             artists: Array(artists.prefix(3)), tracks: tracks))
        }

        // Radios for artists on heavy rotation: their own tracks, then the
        // artists closest to them (sittings, Deezer, genres, family).
        let heavy = artistPlays30.filter { $0.value >= 15 }.sorted { $0.value > $1.value }.prefix(2)
        for (key, _) in heavy {
            let id = "radio:\(key)"
            let own = pool.filter { t in credit(t).map { resolver.keys(forCredit: $0).contains(key) } ?? false }
            guard own.count >= 5, let name = own.first.flatMap(credit).flatMap({ resolver.split($0).first }) else { continue }
            let close = Set(curator.neighbours(of: key, own: own, pool: pool).prefix(10))
            let neighbours = pool.filter { t in curator.artistKey(t).map(close.contains) ?? false }
            let seeds = (input.signals.seeds[id] ?? []).suffix(5)
            let core = curator.core(of: own + neighbours, anchors: [key], seedPaths: Array(seeds))
            let rejected = input.signals.rejected[id] ?? []
            let mine = own.filter { !rejected.contains($0.url.path) }.shuffled(using: &rng).prefix(20)
            var extra: [Track] = []
            for s in seeds.compactMap({ byPath[$0] }) { extra += curator.similar(to: s, in: pool, count: 8) }
            let others = curator.pick(neighbours + extra, core: core, mixID: id, count: 30, rng: &rng)
            let tracks = (Array(mine) + others).shuffled(using: &rng)
            let artists = [name] + artistsByWeight(others).filter { $0 != name }.prefix(2)
            let title = "\(name) Radio"
            mixes.append(Mix(id: id, name: title, hue: hue(for: title), leadArtist: name,
                             artists: Array(artists), tracks: tracks))
        }
        return Array(mixes.prefix(6))
    }

    /// The tracks mixes may use: every track except Mix Compilations, by the
    /// tag alone (not by titles). An album counts as one if any of its tracks
    /// is tagged, so all of it stays out.
    static func mixPool(tracks: [Track], albums: [Album]) -> [Track] {
        let flagged = Set(albums.filter(\.isMixCompilation).flatMap { $0.tracks.map(\.id) })
        return tracks.filter { !$0.isMixCompilation && !flagged.contains($0.id) }
    }

    // MARK: Recently added

    private static func recentlyAdded(_ albums: [Album], now: Date, cal: Calendar) -> [AlbumPick] {
        albums.compactMap { a -> (Album, Date)? in
            a.tracks.compactMap(\.dateAdded).max().map { (a, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .prefix(20)
        .map { AlbumPick(album: $0.0, note: relativeDay($0.1, now: now, cal: cal)) }
    }

    // MARK: Best sounding

    /// Lossless albums ranked by their weakest track's bit depth, then its
    /// sample rate: 24-bit / 44.1 kHz beats 16-bit / 44.1 kHz, 24/96 beats
    /// 24/48. Whatever the library's best is comes first, however high it goes.
    private static func bestSounding(_ albums: [Album], stats: [String: AlbumStats]) -> [BestPick] {
        let lossless: Set<AudioFileFormat> = [.flac, .wav, .aiff, .alac]
        let picks = albums.compactMap { a -> BestPick? in
            guard a.tracks.count >= 2, a.tracks.allSatisfy({ lossless.contains($0.fileFormat) }),
                  let bits = a.tracks.compactMap(\.bitDepth).min(),
                  let rate = a.tracks.compactMap(\.sampleRate).min() else { return nil }
            let quality = AudioQuality.classify(sampleRate: rate, bitDepth: bits, format: a.tracks[0].fileFormat)
            return BestPick(album: a, bits: bits, rate: rate, quality: quality)
        }
        let sorted = picks.sorted {
            ($0.bits, $0.rate, stats[$0.album.id]?.plays ?? 0) > ($1.bits, $1.rate, stats[$1.album.id]?.plays ?? 0)
        }
        return sorted.count >= 4 ? Array(sorted.prefix(20)) : []
    }

    // MARK: Helpers

    private static let bandNames = [
        ("Your mornings", "What you usually start the day with"),
        ("Your afternoons", "Your usual between lunch and evening"),
        ("Your evenings", "What you tend to play after dinner"),
        ("Your late nights", "What you reach for after 10pm"),
    ]

    /// Morning 5–12, afternoon 12–17, evening 17–22, late night 22–5.
    static func band(_ hour: Int) -> Int {
        switch hour {
        case 5..<12: 0
        case 12..<17: 1
        case 17..<22: 2
        default: 3
        }
    }

    /// "9 days", "3 weeks", "5 months", "2 years".
    static func ago(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        switch days {
        case ..<14: return "\(max(days, 1)) day\(days == 1 ? "" : "s")"
        // Nearest week or month: 89 days reads as 3 months, not 2.
        case ..<60: return "\((days + 3) / 7) weeks"
        case ..<365: return "\((days + 15) / 30) months"
        default:
            let years = days / 365
            return "\(years) year\(years == 1 ? "" : "s")"
        }
    }

    /// "Today", "Yesterday", "This week", "Last week", "3 weeks ago", "March".
    static func relativeDay(_ date: Date, now: Date, cal: Calendar) -> String {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case ..<7: return "This week"
        case ..<14: return "Last week"
        case ..<35: return "\(days / 7) weeks ago"
        default:
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
            return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.abbreviated).year())
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dayNumber(_ date: Date, _ cal: Calendar) -> UInt64 {
        UInt64(max(0, cal.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: date).day ?? 0))
    }
}

/// A small deterministic generator, so a day's mixes and picks come out the
/// same every time Home rebuilds that day.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension String {
    /// A hash that's the same on every launch (`hashValue` is reseeded per run).
    var hashValueStable: Int {
        var h: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 { h = (h ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(truncatingIfNeeded: h >> 1)
    }
}
