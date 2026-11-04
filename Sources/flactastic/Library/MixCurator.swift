import Foundation

/// Picks the tracks for Home's generated mixes by how well each fits the mix,
/// not only by sharing a genre tag. A track is scored against the mix's
/// *core* (the artists you play most within it) on:
///
/// - **Genres, all of them:** how much its full set of genres overlaps the
///   core's, so "Electronic + Ambient" and "Electronic + Hardstyle" no longer
///   count as the same thing.
/// - **Genre group:** the Heavy / Raw / Street / Electric / Smooth / Classic
///   family from Settings › Genre Groups. A track from a different family
///   than most of the mix is left out.
/// - **Artist closeness:** artists you play in the same sittings (your own
///   listening as the ear), plus Deezer's related artists when fetched.
/// - **Era and label:** release year near the core's, a label the core shares.
/// - **Sound:** when a track has been listened to by the on-device analyser,
///   how close its sound fingerprint is to the mix's average. Tracks far
///   from it are dropped as outliers.
/// - **You:** tracks you skip early count against; "Doesn't fit this mix"
///   removes a track from that mix; "More like this" pulls the mix toward
///   a track.
///
/// Pure and synchronous: everything it needs comes in through `Signals`.
struct MixCurator {
    /// What the curator knows beyond the library's tags. All optional: with
    /// none of it, it still scores on genres, groups, era and label.
    struct Signals: Sendable {
        /// Library artist key → related library artist keys (from Deezer).
        var related: [String: Set<String>] = [:]
        /// Track file path → sound fingerprint.
        var fingerprints: [String: SoundFingerprint] = [:]
        /// Mix ID → track file paths that don't fit it.
        var rejected: [String: Set<String>] = [:]
        /// Mix ID → track file paths to steer it toward, newest last.
        var seeds: [String: [String]] = [:]
        var groups = GenreGroups()
        /// Today's mixes if already built: Home shows these as they are.
        var today: MixDay?

        static let empty = Signals()
    }

    let resolver: ArtistResolver
    let signals: Signals
    /// Artist key ↔ artist key, how often played in the same sitting (0…1).
    let graph: ArtistGraph
    /// Track file path → share of its plays that were skipped early (0…1).
    let skipRate: [String: Double]
    /// Artist key → minutes listened recently.
    let artistMinutes: [String: Double]

    init(resolver: ArtistResolver, signals: Signals, events: [PlayEvent], tracks: [Track],
         artistMinutes: [String: Double]) {
        self.resolver = resolver
        self.signals = signals
        self.artistMinutes = artistMinutes
        graph = ArtistGraph(events: events, resolver: resolver)
        let paths = Dictionary(tracks.map { ($0.id, $0.url.path) }, uniquingKeysWith: { a, _ in a })
        var plays: [String: (skips: Int, all: Int)] = [:]
        for e in events {
            guard let path = paths[e.trackID] else { continue }
            var p = plays[path, default: (0, 0)]
            p.all += 1
            if !e.counted && e.secondsListened < 30 { p.skips += 1 }
            plays[path] = p
        }
        skipRate = plays.compactMapValues { $0.all >= 2 ? Double($0.skips) / Double($0.all) : nil }
    }

    // MARK: Pieces of a track

    static func genres(_ t: Track) -> [String] {
        ([t.genre].compactMap { $0 } + t.secondaryGenres)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    func artistKey(_ t: Track) -> String? {
        (t.albumArtist ?? t.artist).flatMap { resolver.keys(forCredit: $0).first }
    }

    func tier(_ t: Track) -> GenreTier? {
        signals.groups.tier(for: Self.genres(t))
    }

    // MARK: The core

    /// What a mix is about, from the tracks of its most-played artists.
    struct Core {
        var artists: Set<String>
        /// Genre → weight, summing to 1.
        var genres: [String: Double]
        /// The genre family most of the mix is in, when one clearly leads.
        var tier: GenreTier?
        var year: Double?
        var labels: Set<String>
        var centroid: SoundFingerprint?
    }

    /// The core of a set of candidate tracks: its top artists by your
    /// listening (or by how many tracks they have), up to eight of them.
    /// `anchors` are always in it (a radio's own artist, "more like this").
    func core(of candidates: [Track], anchors: Set<String> = [], seedPaths: [String] = []) -> Core {
        var weight: [String: Double] = [:]
        for t in candidates { if let k = artistKey(t) { weight[k, default: 0] += 1 + (artistMinutes[k] ?? 0) / 30 } }
        var artists = Set(weight.sorted { $0.value > $1.value }.prefix(8).map(\.key))
        artists.formUnion(anchors)
        let seeds = Set(seedPaths)
        let coreTracks = candidates.filter { t in artistKey(t).map(artists.contains) ?? false || seeds.contains(t.url.path) }
        let base = coreTracks.isEmpty ? candidates : coreTracks

        var genres: [String: Double] = [:]
        var tiers: [GenreTier: Int] = [:]
        var years: [Int] = []
        var labels: [String: Int] = [:]
        var prints: [SoundFingerprint] = []
        for t in base {
            let g = Self.genres(t)
            for name in g { genres[name, default: 0] += 1 / Double(g.count) }
            if let tier = tier(t) { tiers[tier, default: 0] += 1 }
            if let y = t.year { years.append(y) }
            if let l = t.label?.lowercased(), !l.isEmpty { labels[l, default: 0] += 1 }
            if let p = signals.fingerprints[t.url.path] { prints.append(p) }
        }
        // Seeds count double toward the sound and genres.
        for path in seedPaths { if let p = signals.fingerprints[path] { prints.append(p); prints.append(p) } }
        let total = genres.values.reduce(0, +)
        if total > 0 { genres = genres.mapValues { $0 / total } }
        let tierTotal = tiers.values.reduce(0, +)
        let lead = tiers.max { $0.value < $1.value }
        years.sort()
        return Core(
            artists: artists,
            genres: genres,
            tier: lead.flatMap { tierTotal >= 4 && Double($0.value) / Double(tierTotal) >= 0.6 ? $0.key : nil },
            year: years.isEmpty ? nil : Double(years[years.count / 2]),
            labels: Set(labels.filter { $0.value >= 2 }.keys),
            centroid: prints.count >= 5 ? SoundFingerprint.mean(prints) : nil
        )
    }

    // MARK: Fit

    /// How closely two library artists go together, 0…1: played in the same
    /// sittings, or related on Deezer.
    func closeness(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let related = (signals.related[a]?.contains(b) ?? false) || (signals.related[b]?.contains(a) ?? false)
        return min(1, graph.strength(a, b) + (related ? 0.6 : 0))
    }

    /// How well a track fits a core, 0…1, or nil when it clearly doesn't:
    /// another genre family, or a sound far from the mix's.
    func fit(_ t: Track, to core: Core) -> Double? {
        if let want = core.tier, let have = tier(t), have != want { return nil }

        let g = Self.genres(t)
        let genre = g.isEmpty ? 0 : g.reduce(0) { $0 + (core.genres[$1] ?? 0) } / max(1, core.genres.values.max() ?? 1) / Double(g.count)

        var artist = 0.0
        if let k = artistKey(t) {
            artist = core.artists.contains(k) ? 1 : core.artists.map { closeness(k, $0) }.max() ?? 0
        }

        var era = 0.5
        if let y = t.year, let c = core.year { era = max(0, 1 - abs(Double(y) - c) / 12) }
        let label = t.label.map { core.labels.contains($0.lowercased()) ? 1.0 : 0 } ?? 0

        var sound = 0.5
        if let c = core.centroid, let p = signals.fingerprints[t.url.path] {
            let s = p.similarity(to: c)
            if s < 0.35 { return nil }
            sound = s
        }

        let skip = skipRate[t.url.path] ?? 0
        let score = 0.30 * min(1, genre) + 0.25 * artist + 0.25 * sound + 0.12 * era + 0.08 * label
        return max(0, score - 0.35 * skip)
    }

    /// The best-fitting tracks, drawn so better fits are likelier but the mix
    /// still changes day to day. Rejected tracks never come back; the lowest
    /// scorers (well under the rest) are dropped as outliers first.
    func pick(_ candidates: [Track], core: Core, mixID: String, count: Int, rng: inout SeededRandom) -> [Track] {
        let rejected = signals.rejected[mixID] ?? []
        var scored = candidates
            .filter { !rejected.contains($0.url.path) }
            .compactMap { t in fit(t, to: core).map { (t, $0) } }
        guard !scored.isEmpty else { return [] }
        let sorted = scored.map(\.1).sorted()
        let q1 = sorted[sorted.count / 4], q3 = sorted[(sorted.count * 3) / 4]
        let floor = max(0.12, q1 - 1.5 * (q3 - q1))
        scored = scored.filter { $0.1 >= floor }

        // Weighted draw without replacement (Efraimidis–Spirakis keys).
        let keyed = scored.map { t, s -> (Track, Double) in
            let u = Double.random(in: 0.0001..<1, using: &rng)
            return (t, pow(u, 1 / max(0.01, s * s)))
        }
        return keyed.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
    }

    /// Library artists ranked by closeness to `artist`, for its radio:
    /// sittings and Deezer first, then shared genres and family.
    func neighbours(of artist: String, own: [Track], pool: [Track]) -> [String] {
        let theirs = core(of: own, anchors: [artist])
        var best: [String: Double] = [:]
        for t in pool {
            guard let k = artistKey(t), k != artist, let f = fit(t, to: theirs) else { continue }
            best[k] = max(best[k] ?? 0, 0.5 * closeness(artist, k) + 0.5 * f)
        }
        return best.filter { $0.value >= 0.3 }.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Tracks most like `seed` within `pool`: for "More like this".
    func similar(to seed: Track, in pool: [Track], count: Int) -> [Track] {
        let c = core(of: [seed], anchors: artistKey(seed).map { [$0] } ?? [], seedPaths: [seed.url.path])
        var withSound = c
        if c.centroid == nil, let p = signals.fingerprints[seed.url.path] { withSound.centroid = p }
        return pool.filter { $0.url.path != seed.url.path }
            .compactMap { t in fit(t, to: withSound).map { (t, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(count).map(\.0)
    }
}

// MARK: - Listening graph

/// Which artists you play in the same sitting: a session is plays no more
/// than 30 minutes apart. Each session links every pair of artists in it,
/// weighted down for long, varied sessions; strength is normalised so the
/// closest pair in your history is 1.
struct ArtistGraph: Sendable {
    private var weights: [String: [String: Double]] = [:]
    private var peak = 1.0

    init(events: [PlayEvent], resolver: ArtistResolver) {
        let sorted = events.filter { $0.secondsListened >= 30 }.sorted { $0.date < $1.date }
        var session: Set<String> = []
        var last: Date?
        func close() {
            guard session.count >= 2 else { session = []; return }
            let w = 1 / Double(session.count - 1)
            for a in session { for b in session where a < b {
                weights[a, default: [:]][b, default: 0] += w
                weights[b, default: [:]][a, default: 0] += w
            } }
            session = []
        }
        for e in sorted {
            if let l = last, e.date.timeIntervalSince(l) > 30 * 60 { close() }
            if let a = e.artist, let k = resolver.keys(forCredit: a).first { session.insert(k) }
            last = e.date
        }
        close()
        peak = max(1, weights.values.flatMap(\.values).max() ?? 1)
    }

    func strength(_ a: String, _ b: String) -> Double {
        min(1, (weights[a]?[b] ?? 0) / peak * 1.5)
    }
}

// MARK: - Sound fingerprint

/// A track's sound, as Apple's built-in sound classifier hears a few seconds
/// of it: its strongest categories (music genres, instruments, voice,
/// texture) and their confidence. Kept sparse, top 32.
struct SoundFingerprint: Codable, Sendable, Equatable {
    var classes: [String: Float]

    func similarity(to other: SoundFingerprint) -> Double {
        var dot: Float = 0, a: Float = 0, b: Float = 0
        for (k, v) in classes { a += v * v; if let w = other.classes[k] { dot += v * w } }
        for v in other.classes.values { b += v * v }
        guard a > 0, b > 0 else { return 0 }
        return Double(dot / (a.squareRoot() * b.squareRoot()))
    }

    static func mean(_ prints: [SoundFingerprint]) -> SoundFingerprint {
        var sum: [String: Float] = [:]
        for p in prints { for (k, v) in p.classes { sum[k, default: 0] += v } }
        let n = Float(max(1, prints.count))
        return SoundFingerprint(classes: sum.mapValues { $0 / n })
    }
}
