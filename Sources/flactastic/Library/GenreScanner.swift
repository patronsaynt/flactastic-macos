import Foundation

/// Fills in missing genres, on three occasions, most urgent first:
///
/// 1. **A track plays** (and the one or two after it in the queue) with no
///    genre at all: its album is looked up, and the playing track written.
/// 2. **Something is imported** (a sheet, a download, a new file found in
///    the library folder): its albums, or loose tracks, are looked up and
///    written, with a status message while it happens, then its lyrics.
/// 3. **Settings › Scan Library for Genres:** every album with untagged
///    tracks, in two stages (identify on Deezer, then genres from
///    MusicBrainz), with progress and time left.
///
/// Only ever writes to a track whose genre tag is empty, in the library and
/// in the file itself. Every album's answer is remembered (`GenreCache`), so
/// nothing is asked twice and later tracks of a known album fill instantly.
@Observable
@MainActor
final class GenreScanner {
    static let shared = GenreScanner()

    // MARK: State for the UI

    struct ScanProgress: Equatable {
        enum Stage: Equatable { case identifying, pulling }
        var stage: Stage
        var done: Int
        var total: Int
        var written: Int
        var started: Date
        /// Seconds left, once there's enough to estimate from.
        var remaining: TimeInterval?
    }

    /// The library scan, while it runs.
    private(set) var scan: ScanProgress?
    /// How a finished scan went, for its summary in Settings.
    struct ScanSummary: Identifiable, Equatable {
        struct Missed: Identifiable, Equatable {
            let id: String
            let title: String
            let artist: String?
        }
        let id = UUID()
        var scanned: Int
        var found: Int
        var tracksWritten: Int
        /// Albums neither service knew a genre for.
        var missed: [Missed]
        /// Albums that couldn't be checked (offline, refused): tried next scan.
        var unreachable: Int
        var stopped: Bool
    }

    /// The last scan's summary until Settings has shown it.
    var pendingSummary: ScanSummary?
    /// The last scan's figures (kept after the summary is dismissed).
    private(set) var lastScan: (albums: Int, tracksWritten: Int, notFound: Int)?
    /// One line for the status pill: what an import (or scan) is doing now.
    private(set) var status: String?

    // MARK: Wiring

    private weak var library: LibraryStore?
    private var writer: MetadataWriter?
    private var lyrics: LyricsFetcher?
    private var settings: Settings?

    private var knownTrackIDs: Set<UUID>?
    private var scanTask: Task<Void, Never>?
    private var importQueue: [ImportJob] = []
    private var importTask: Task<Void, Never>?
    private var playing: Set<String> = []

    private struct ImportJob {
        let title: String
        let tracks: [Track]
        let asAlbum: Bool
    }

    private init() {}

    func attach(library: LibraryStore, writer: MetadataWriter, lyrics: LyricsFetcher, settings: Settings) {
        self.library = library
        self.writer = writer
        self.lyrics = lyrics
        self.settings = settings
    }

    private static func isUntagged(_ t: Track) -> Bool {
        (t.genre ?? "").trimmingCharacters(in: .whitespaces).isEmpty && t.secondaryGenres.isEmpty
    }

    private func finder() async -> GenreFinder {
        let vocabulary = Array(Set((library?.tracks ?? []).flatMap { [$0.genre].compactMap { $0 } + $0.secondaryGenres }))
        return GenreFinder(known: await GenreCache.shared.knownGenres(), vocabulary: vocabulary,
                           groups: settings?.genreGroups ?? GenreGroups(), artistCache: GenreCache.shared)
    }

    // MARK: 1. A track plays

    /// The playing track and the next few: looked up only if untagged.
    /// The playing one goes ahead of everything else.
    func trackStarted(_ track: Track?, upcoming: [Track]) {
        guard let library, library.hasCompletedInitialLoad else { return }
        for (i, t) in ([track].compactMap { $0 } + upcoming.prefix(2)).enumerated() {
            guard Self.isUntagged(t), !t.isMixCompilation, !playing.contains(t.url.path) else { continue }
            playing.insert(t.url.path)
            let urgency: MusicBrainzClient.Urgency = i == 0 ? .playing : .importing
            Task { [weak self] in
                if i > 0 { try? await Task.sleep(for: .seconds(Double(i) * 2)) }
                await self?.fill([t], album: library.album(for: t), urgency: urgency, stage: nil)
                self?.playing.remove(t.url.path)
            }
        }
    }

    // MARK: 2. Imports

    /// Called on every library change: anything new since last time (after
    /// the first load) is treated as an import.
    func libraryChanged() {
        guard let library, library.hasCompletedInitialLoad else { return }
        // A folder still loading holds placeholder tracks, not imports: start
        // counting again once its tags are in.
        guard !library.isLoadingFolder else { knownTrackIDs = nil; return }
        let ids = Set(library.tracks.map(\.id))
        guard let known = knownTrackIDs else { knownTrackIDs = ids; return }
        knownTrackIDs = ids
        let fresh = library.tracks.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let byAlbum = Dictionary(grouping: fresh) { library.album(for: $0)?.id ?? $0.url.path }
        // Hundreds of albums at once is a new music folder, not an import:
        // that's for Settings › Scan Library for Genres, not the status pill.
        guard byAlbum.count <= 50 else { return }
        for (_, tracks) in byAlbum {
            let first = tracks[0]
            let asAlbum = tracks.count > 1 && !(library.album(for: first)?.isCompilation ?? false)
            importQueue.append(ImportJob(title: asAlbum ? (first.album ?? first.title) : first.title,
                                         tracks: tracks, asAlbum: asAlbum))
        }
        runImports()
    }

    private func runImports() {
        guard importTask == nil else { return }
        importTask = Task { [weak self] in
            while let self, !self.importQueue.isEmpty {
                let job = self.importQueue.removeFirst()
                let untagged = job.tracks.filter(Self.isUntagged)
                if job.asAlbum, !untagged.isEmpty {
                    let album = self.library?.album(for: untagged[0])
                    await self.fill(untagged, album: album, urgency: .importing) { stage in
                        await MainActor.run { self.status = Self.message(stage, job.title) }
                    }
                } else {
                    // Loose tracks and compilations: each looked up on its own.
                    for t in untagged {
                        await self.fill([t], album: nil, urgency: .importing) { stage in
                            await MainActor.run { self.status = Self.message(stage, t.title) }
                        }
                    }
                }
                await self.importLyrics(job)
            }
            self?.status = self?.scanStatus
            self?.importTask = nil
        }
    }

    /// Fetches lyrics for an import (if lookup is on), saying so while it
    /// waits for them, up to 20 seconds.
    private func importLyrics(_ job: ImportJob) async {
        guard let lyrics, let settings, settings.lyricsLookupEnabled else { return }
        let tracks = job.tracks.filter { !$0.isMixCompilation }
        guard !tracks.isEmpty else { return }
        status = Self.message(.lyrics, job.title)
        lyrics.prefetch(tracks: tracks, enabled: true, saveToFile: settings.saveLyricsToFiles)
        let deadline = Date().addingTimeInterval(min(20, 1 + Double(tracks.count) * 0.5))
        while Date() < deadline, !tracks.allSatisfy({ lyrics.isSettled($0) }) {
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private static func message(_ stage: GenreJobStage, _ title: String) -> String {
        switch stage {
        case .identifying: "Identifying \(title)…"
        case .pulling: "Pulling genres for \(title)…"
        case .writing: "Writing genres for \(title)…"
        case .lyrics: "Importing lyrics for \(title)…"
        }
    }

    // MARK: 3. Library scan

    var isScanning: Bool { scanTask != nil }

    /// Every album with untagged tracks: first identified on Deezer (four
    /// at a time), then genres from MusicBrainz (one a second), written as
    /// each arrives. Albums already answered are filled from what's saved.
    func scanLibrary() {
        guard scanTask == nil, let library, library.hasCompletedInitialLoad else { return }
        let albums = library.albums.filter { $0.tracks.contains(where: Self.isUntagged) }
        lastScan = nil
        scan = ScanProgress(stage: .identifying, done: 0, total: albums.count, written: 0, started: Date())
        status = scanStatus
        scanTask = Task { [weak self] in
            await self?.runScan(albums)
            self?.flush()
            await GenreCache.shared.save()
            self?.scanTask = nil
            self?.scan = nil
            self?.status = nil
        }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    private var scanStatus: String? {
        guard let scan else { return nil }
        return scan.stage == .identifying ? "Identifying albums…" : "Pulling genres…"
    }

    private func runScan(_ albums: [Album]) async {
        let finder = await finder()
        var notFound = 0
        var written = 0
        var found = 0
        var unreachable = 0
        var missed: [ScanSummary.Missed] = []
        func miss(_ album: Album) {
            notFound += 1
            missed.append(.init(id: album.id, title: album.name, artist: album.albumArtist ?? album.artist))
        }
        func summarize(stopped: Bool) {
            lastScan = (found + notFound + unreachable, written, notFound)
            pendingSummary = ScanSummary(scanned: found + notFound + unreachable, found: found, tracksWritten: written,
                                         missed: missed.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                                         unreachable: unreachable, stopped: stopped)
        }

        // Stage 1: what's already known fills now; the rest is identified
        // on Deezer (cheap, parallel), so stage 2 only waits on MusicBrainz.
        var pending: [(Album, DeezerClient.Album?)] = []
        await withTaskGroup(of: (Album, DeezerClient.Album?, AlbumState).self) { group in
            var iterator = albums.makeIterator()
            func next() {
                guard let album = iterator.next() else { return }
                group.addTask {
                    let key = album.id
                    if let cached = await GenreCache.shared.album(key) {
                        return (album, nil, cached.found == nil ? .knownMissing : .known(cached.found!))
                    }
                    if album.isCompilation { return (album, nil, .needsTracks) }
                    let artist = album.albumArtist ?? album.artist ?? ""
                    let d = try? await DeezerClient.shared.album(artist: artist, title: album.name, trackCount: album.tracks.count)
                    return (album, d, .needsLookup)
                }
            }
            for _ in 0..<4 { next() }
            for await (album, deezer, state) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                switch state {
                case .known(let answer):
                    written += await write(answer, to: album.tracks)
                    found += 1
                case .knownMissing: miss(album)
                case .needsLookup, .needsTracks: pending.append((album, deezer))
                }
                advance(written: written)
                next()
            }
        }
        guard !Task.isCancelled else { summarize(stopped: true); return }

        // Stage 2: MusicBrainz, one request a second.
        if let p = scan {
            scan = ScanProgress(stage: .pulling, done: 0, total: pending.count, written: p.written, started: Date())
        }
        status = scanStatus
        for (album, deezer) in pending {
            guard !Task.isCancelled else { break }
            let artist = album.albumArtist ?? album.artist ?? ""
            do {
                if album.isCompilation {
                    // A compilation's tracks each have their own artist.
                    var any = false
                    for t in album.tracks where Self.isUntagged(t) {
                        guard !Task.isCancelled else { break }
                        if let answer = try await finder.track(artist: t.artist ?? artist, title: t.title, urgency: .scan) {
                            written += await write(answer, to: [t])
                            any = true
                        }
                    }
                    await GenreCache.shared.store(album: album.id, nil)
                    if any { found += 1 } else { miss(album) }
                } else {
                    let answer = try await lookup(album, artist: artist, deezer: deezer, finder: finder)
                    await GenreCache.shared.store(album: album.id, answer)
                    if let answer {
                        written += await write(answer, to: album.tracks)
                        found += 1
                    } else {
                        miss(album)
                    }
                }
            } catch {
                // Offline or refused: left unrecorded, so the next scan retries it.
                unreachable += 1
            }
            advance(written: written)
        }
        summarize(stopped: Task.isCancelled)
    }

    private enum AlbumState { case known(FoundGenres), knownMissing, needsLookup, needsTracks }

    /// Stage 2 for one album, reusing stage 1's Deezer answer.
    private func lookup(_ album: Album, artist: String, deezer: DeezerClient.Album?, finder: GenreFinder) async throws -> FoundGenres? {
        guard let deezer else {
            return try await finder.album(artist: artist, title: album.name, trackCount: album.tracks.count, urgency: .scan)
        }
        return try await finder.album(identified: deezer, artist: artist, title: album.name, urgency: .scan)
    }

    /// One more album through the current stage. Reads the progress into a
    /// local, changes it, and stores it back in one assignment: changing
    /// `scan` while reading it in the same statement is an exclusivity
    /// violation (it crashed the first scan).
    private func advance(written: Int) {
        guard var p = scan else { return }
        p.done += 1
        p.written = written
        p.remaining = estimate(started: p.started, done: p.done, total: p.total)
        scan = p
    }

    private func estimate(started: Date?, done: Int, total: Int) -> TimeInterval? {
        guard let started, done >= 5 else { return nil }
        let per = Date().timeIntervalSince(started) / Double(done)
        return per * Double(max(0, total - done))
    }

    // MARK: Looking up and writing

    /// Looks up (or recalls) genres for these tracks, then writes them to
    /// the ones still untagged.
    private func fill(_ tracks: [Track], album: Album?, urgency: MusicBrainzClient.Urgency,
                      stage: (@Sendable (GenreJobStage) async -> Void)?) async {
        guard let first = tracks.first else { return }
        // An album's answer is shared by its tracks; a compilation's isn't.
        let album = album?.isCompilation == true ? nil : album
        let key = album?.id ?? "track:\(first.url.path)"
        var found: FoundGenres?
        if let cached = await GenreCache.shared.album(key) {
            found = cached.found
        } else {
            let finder = await finder()
            do {
                if let album {
                    found = try await finder.album(artist: album.albumArtist ?? album.artist ?? "", title: album.name,
                                                   trackCount: album.tracks.count, urgency: urgency, stage: stage)
                } else {
                    found = try await finder.track(artist: first.artist ?? first.albumArtist ?? "", title: first.title,
                                                   urgency: urgency, stage: stage)
                }
                await GenreCache.shared.store(album: key, found)
            } catch {
                return // Offline: try again next time.
            }
        }
        guard let found else { return }
        await stage?(.writing)
        _ = await write(found, to: tracks)
    }

    /// Writes to every track here still untagged, in the library and in its
    /// file; returns how many were written.
    @discardableResult
    private func write(_ found: FoundGenres, to tracks: [Track]) async -> Int {
        guard let writer, let library else { return 0 }
        // As the library has them now, not as they were when the job began.
        let ids = Set(tracks.map(\.id))
        let current = library.tracks.filter { ids.contains($0.id) && Self.isUntagged($0) }
        var count = 0
        for t in current where !pendingWrites.keys.contains(t.id) {
            // A file playback is using waits until the track finishes or is
            // skipped (see PlaybackFileGuard); counted now, written then.
            if PlaybackFileGuard.shared.isInUse(t.url) {
                count += 1
                PlaybackFileGuard.shared.whenFree(t.url) { [weak self] in
                    guard let self, let library = self.library,
                          let now = library.tracks.first(where: { $0.id == t.id }), Self.isUntagged(now),
                          let written = try? await writer.writeGenreIfEmpty(to: now, primary: found.primary, secondary: found.secondary)
                    else { return }
                    self.pendingWrites[t.id] = written
                    self.scheduleFlush(soon: true)
                }
                continue
            }
            if let written = try? await writer.writeGenreIfEmpty(to: t, primary: found.primary, secondary: found.secondary) {
                pendingWrites[t.id] = written
                count += 1
            }
        }
        if count > 0 { scheduleFlush(soon: scan == nil) }
        return count
    }

    /// Written tracks, waiting to go into the library together: during a
    /// scan, every few seconds rather than per album, since each library
    /// change makes Home rebuild.
    private var pendingWrites: [UUID: Track] = [:]
    private var flushTask: Task<Void, Never>?

    private func scheduleFlush(soon: Bool) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(soon ? 0.3 : 6))
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard let library, !pendingWrites.isEmpty else { return }
        let updated = Array(pendingWrites.values)
        pendingWrites = [:]
        knownTrackIDs?.formUnion(updated.map(\.id))
        library.replaceTracks(updated)
    }
}
