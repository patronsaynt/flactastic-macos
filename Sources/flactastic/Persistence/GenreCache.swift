import Foundation

/// What genre lookups have learned, kept in Application Support so nothing
/// is asked twice: each album's answer (or that there wasn't one, retried
/// after 30 days), each MusicBrainz artist's genres (refreshed after 90),
/// and MusicBrainz's list of real genre names (refreshed after 30).
actor GenreCache {
    static let shared = GenreCache()

    struct AlbumEntry: Codable, Sendable {
        var found: FoundGenres?
        var checked: Date
    }

    private struct ArtistEntry: Codable { var genres: [String: Int]; var fetched: Date }
    private struct Stored: Codable {
        var albums: [String: AlbumEntry] = [:]
        var artists: [String: ArtistEntry] = [:]
        var known: [String] = []
        var knownFetched: Date?
    }

    private var stored = Stored()
    private var loaded = false
    private var dirty = 0

    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("flactastic/genres", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("genre_lookups.json")
    }()

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(Stored.self, from: d) { stored = s }
    }

    // MARK: Albums

    /// A still-current answer for this album (found, or not found within 30 days).
    func album(_ key: String) -> AlbumEntry? {
        load()
        guard let e = stored.albums[key] else { return nil }
        if e.found == nil, e.checked < Date().addingTimeInterval(-30 * 86_400) { return nil }
        return e
    }

    func store(album key: String, _ found: FoundGenres?) {
        load()
        stored.albums[key] = AlbumEntry(found: found, checked: Date())
        noteChange()
    }

    // MARK: Artists

    func artist(_ id: String) -> [MusicBrainzClient.Genre]? {
        load()
        guard let e = stored.artists[id], e.fetched > Date().addingTimeInterval(-90 * 86_400) else { return nil }
        return e.genres.map { .init(name: $0.key, votes: $0.value) }.sorted { $0.votes > $1.votes }
    }

    func store(artist id: String, genres: [MusicBrainzClient.Genre]) {
        load()
        stored.artists[id] = ArtistEntry(genres: Dictionary(genres.map { ($0.name, $0.votes) }, uniquingKeysWith: max), fetched: Date())
        noteChange()
    }

    // MARK: Genre names

    /// MusicBrainz's genre names, fetched when missing or a month old.
    /// Empty if it can't be reached (tags are then trusted unfiltered).
    func knownGenres() async -> Set<String> {
        load()
        if let at = stored.knownFetched, at > Date().addingTimeInterval(-30 * 86_400), !stored.known.isEmpty {
            return Set(stored.known)
        }
        guard let fresh = try? await MusicBrainzClient.shared.allGenres(), !fresh.isEmpty else { return Set(stored.known) }
        stored.known = fresh.sorted()
        stored.knownFetched = Date()
        save()
        return fresh
    }

    // MARK: Counts and saving

    var counts: (found: Int, notFound: Int) {
        let all = stored.albums.values
        return (all.filter { $0.found != nil }.count, all.filter { $0.found == nil }.count)
    }

    /// Forgets every album answer (Debug): the next scan asks again.
    func clearAlbums() {
        load()
        stored.albums = [:]
        save()
    }

    private func noteChange() {
        dirty += 1
        if dirty >= 20 { save() }
    }

    func save() {
        dirty = 0
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: Self.url, options: .atomic) }
    }
}
