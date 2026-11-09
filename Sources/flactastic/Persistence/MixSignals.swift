import Foundation

/// What Home's mixes know beyond the library's tags, kept between launches
/// in Application Support:
///
/// - **Related artists** from Deezer, for the library's most-played and
///   biggest artists, refreshed every 30 days.
/// - **Sound fingerprints**, made on this Mac in the background, one track
///   at a time (see `SoundFingerprinter`).
/// - **Your feedback:** tracks that don't fit a mix, and tracks to steer a
///   mix toward ("More like this").
///
/// `revision` changes when any of it does, so Home rebuilds its mixes.
@Observable
@MainActor
final class MixSignals {
    static let shared = MixSignals()

    private(set) var revision = 0

    /// Today's mixes as first built, so they hold still all day: plays,
    /// new fingerprints and Deezer lists don't touch them until tomorrow.
    /// Only a rating edits one, in place.
    private var today: MixDay?
    /// Edition ID (`mixID@day`) → the playlist it was saved as.
    private var saved: [String: UUID] = [:]

    private struct Related: Codable { var names: [String]; var fetched: Date }
    private struct Feedback: Codable { var rejected: [String: Set<String>] = [:]; var seeds: [String: [String]] = [:] }

    private var related: [String: Related] = [:]
    private var fingerprints: [String: SoundFingerprint] = [:]
    private var feedback = Feedback()
    /// Files the analyser couldn't read this run, so it doesn't retry them.
    private var unreadable: Set<String> = []

    private var relatedTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var loaded = false

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("flactastic/mixes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static var relatedURL: URL { dir.appendingPathComponent("related_artists.json") }
    private static var fingerprintsURL: URL { dir.appendingPathComponent("sound_fingerprints.json") }
    private static var feedbackURL: URL { dir.appendingPathComponent("feedback.json") }
    private static var todayURL: URL { dir.appendingPathComponent("todays_mixes.json") }
    private static var savedURL: URL { dir.appendingPathComponent("saved_mixes.json") }

    private init() {}

    // MARK: Reading

    /// Everything as the curator takes it, with Deezer's names resolved to
    /// this library's artist keys.
    func signals(resolver: ArtistResolver, groups: GenreGroups) -> MixCurator.Signals {
        if !loaded { loadAll() }
        var map: [String: Set<String>] = [:]
        for (key, entry) in related {
            map[key] = Set(entry.names.compactMap { resolver.keys(forCredit: $0).first })
        }
        return MixCurator.Signals(related: map, fingerprints: fingerprints,
                                  rejected: feedback.rejected, seeds: feedback.seeds, groups: groups,
                                  today: today)
    }

    // MARK: Today's mixes

    /// Keeps the day's freshly built mixes; ignored if the day already has some.
    func storeToday(_ mixes: [HomeFeed.Mix], day: String) {
        if !loaded { loadAll() }
        guard today?.day != day, !mixes.isEmpty else { return }
        today = MixDay(day: day, mixes: mixes.map(StoredMix.init))
        Self.write(today, to: Self.todayURL)
    }

    /// Edits one of today's mixes' track list in place, then rebuilds Home.
    func editToday(_ mixID: String, _ change: (inout [String]) -> Void) {
        guard var day = today, let i = day.mixes.firstIndex(where: { $0.id == mixID }) else { return }
        change(&day.mixes[i].paths)
        today = day
        Self.write(day, to: Self.todayURL)
    }

    // MARK: Saved as playlists

    func savedPlaylist(for editionID: String) -> UUID? {
        if !loaded { loadAll() }
        return saved[editionID]
    }

    func recordSaved(_ playlistID: UUID, for editionID: String) {
        saved[editionID] = playlistID
        Self.write(saved, to: Self.savedURL)
        revision += 1
    }

    // MARK: Feedback

    /// Down-rating: remembered for every future build of this mix, and
    /// today's list loses the track and gains `replacement` at its end.
    func reject(_ track: Track, from mixID: String, replacement: Track?) {
        feedback.rejected[mixID, default: []].insert(track.url.path)
        feedback.seeds[mixID]?.removeAll { $0 == track.url.path }
        saveFeedback()
        editToday(mixID) { paths in
            paths.removeAll { $0 == track.url.path }
            if let r = replacement, !paths.contains(r.url.path) { paths.append(r.url.path) }
        }
        revision += 1
    }

    /// Up-rating: future builds lean toward the track, and today's list gets
    /// `inserted` right after it in place of the `dropped` weakest fits.
    func steer(_ mixID: String, toward track: Track, inserted: [Track], dropped: Set<String>) {
        var list = feedback.seeds[mixID, default: []].filter { $0 != track.url.path }
        list.append(track.url.path)
        feedback.seeds[mixID] = Array(list.suffix(5))
        feedback.rejected[mixID]?.remove(track.url.path)
        saveFeedback()
        editToday(mixID) { paths in
            paths.removeAll { dropped.contains($0) }
            let new = inserted.map(\.url.path).filter { !paths.contains($0) }
            let at = paths.firstIndex(of: track.url.path).map { $0 + 1 } ?? paths.endIndex
            paths.insert(contentsOf: new, at: at)
        }
        revision += 1
    }

    /// Clears a mix's feedback.
    /// Forgets every rating on every mix (Settings › Debug). Today's lists
    /// stay as they are; from the next build, mixes are made without them.
    func resetAllRatings() {
        feedback = Feedback()
        saveFeedback()
        revision += 1
    }

    /// Throws away today's mixes, so Home builds a fresh set now (Debug).
    func rebuildToday() {
        if !loaded { loadAll() }
        today = nil
        try? FileManager.default.removeItem(at: Self.todayURL)
        revision += 1
    }

    /// How many ratings are remembered: tracks marked as not fitting, and
    /// tracks mixes lean toward.
    var ratingCounts: (doesntFit: Int, moreLike: Int) {
        if !loaded { loadAll() }
        return (feedback.rejected.values.reduce(0) { $0 + $1.count }, feedback.seeds.values.reduce(0) { $0 + $1.count })
    }

    /// How many times a mix has been rerolled today.
    func rerolls(_ mixID: String) -> Int {
        today?.mixes.first { $0.id == mixID }?.rerolls ?? 0
    }

    /// Replaces one of today's mixes with a freshly drawn version of it.
    func replaceToday(with mix: HomeFeed.Mix) {
        guard var day = today, let i = day.mixes.firstIndex(where: { $0.id == mix.id }) else { return }
        day.mixes[i] = StoredMix(mix)
        today = day
        Self.write(day, to: Self.todayURL)
        revision += 1
    }

    // MARK: Background work

    /// Loads what's saved, then fetches related artists and analyses sound
    /// for whatever's missing. Safe to call on every library change.
    func refresh(tracks: [Track], resolver: ArtistResolver, topArtists: [String]) {
        if !loaded { loadAll() }
        fetchRelated(for: topArtists, resolver: resolver)
        analyse(tracks)
    }

    private func fetchRelated(for credits: [String], resolver: ArtistResolver) {
        guard relatedTask == nil else { return }
        let stale = Date.now.addingTimeInterval(-30 * 86_400)
        let wanted = credits.compactMap { credit -> (String, String)? in
            guard let key = resolver.keys(forCredit: credit).first else { return nil }
            if let r = related[key], r.fetched > stale { return nil }
            return (key, resolver.split(credit).first ?? credit)
        }
        guard !wanted.isEmpty else { return }
        relatedTask = Task { [weak self] in
            var changed = 0
            for (key, name) in wanted {
                guard !Task.isCancelled else { break }
                let names: [String]
                do {
                    guard let artist = try await DeezerClient.shared.searchArtist(name: name) else {
                        self?.related[key] = Related(names: [], fetched: .now)
                        continue
                    }
                    names = try await DeezerClient.shared.relatedArtists(id: artist.id)
                } catch {
                    continue // Offline or refused: try again next refresh.
                }
                self?.related[key] = Related(names: names, fetched: .now)
                changed += 1
                if changed % 10 == 0 { self?.saveRelated(); self?.revision += 1 }
            }
            self?.saveRelated()
            if changed > 0 { self?.revision += 1 }
            self?.relatedTask = nil
        }
    }

    private func analyse(_ tracks: [Track]) {
        guard analysisTask == nil else { return }
        let todo = tracks.map(\.url).filter { fingerprints[$0.path] == nil && !unreadable.contains($0.path) }
        guard !todo.isEmpty else { return }
        analysisTask = Task { [weak self] in
            var done = 0
            for url in todo {
                guard !Task.isCancelled else { break }
                if let print = await SoundFingerprinter.fingerprint(of: url) {
                    self?.fingerprints[url.path] = print
                } else {
                    self?.unreadable.insert(url.path)
                }
                done += 1
                // Rebuild the mixes now and then rather than per track.
                if done % 250 == 0 { self?.saveFingerprints(); self?.revision += 1 }
            }
            self?.saveFingerprints()
            self?.revision += 1
            self?.analysisTask = nil
        }
    }

    // MARK: Storage

    private func loadAll() {
        loaded = true
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: Self.relatedURL), let v = try? dec.decode([String: Related].self, from: d) { related = v }
        if let d = try? Data(contentsOf: Self.fingerprintsURL), let v = try? dec.decode([String: SoundFingerprint].self, from: d) { fingerprints = v }
        if let d = try? Data(contentsOf: Self.feedbackURL), let v = try? dec.decode(Feedback.self, from: d) { feedback = v }
        if let d = try? Data(contentsOf: Self.todayURL), let v = try? dec.decode(MixDay.self, from: d) { today = v }
        if let d = try? Data(contentsOf: Self.savedURL), let v = try? dec.decode([String: UUID].self, from: d) { saved = v }
    }

    private func saveRelated() { Self.write(related, to: Self.relatedURL) }
    private func saveFeedback() { Self.write(feedback, to: Self.feedbackURL) }
    private func saveFingerprints() {
        let snapshot = fingerprints, url = Self.fingerprintsURL
        Task.detached(priority: .utility) { Self.write(snapshot, to: url) }
    }

    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

/// One day's generated mixes, as built that morning.
struct MixDay: Codable, Sendable {
    var day: String
    var mixes: [StoredMix]
}

/// A generated mix with its tracks as file paths.
struct StoredMix: Codable, Sendable {
    var id: String
    var name: String
    var hue: Int
    var leadArtist: String
    var artists: [String]
    var paths: [String]
    /// Times rerolled today (nil in files from before rerolls).
    var rerolls: Int?

    init(_ mix: HomeFeed.Mix) {
        id = mix.id; name = mix.name; hue = mix.hue
        leadArtist = mix.leadArtist; artists = mix.artists
        paths = mix.tracks.map(\.url.path)
        rerolls = mix.rerolls
    }
}
