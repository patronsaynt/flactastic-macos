import Foundation
import Observation

/// Sends files into the server library (§9.4): hash, `POST`, `PATCH` in
/// 16 MiB chunks from the server's offset, resuming after any break. The
/// server files each upload with the selected Organizer profile; the file
/// then stays here as an offline copy at that path.
///
/// Staging: files go in folder order, one at a time to start; a second lane
/// opens while uploads stay fast and error-free (`UploadLanes`). The next
/// file is hashed while one sends. Everything holds, between chunks, while
/// the user has paused or a streamed track is playing. The library is
/// refreshed once per finished album rather than after every file.
@Observable
@MainActor
final class ServerUploads {
    struct Item: Identifiable, Codable, Equatable {
        enum Status: String, Codable { case waiting, hashing, sending, done, failed }
        let id: UUID
        var file: String
        var name: String
        var trackID: UUID?
        var uploadID: UUID?
        var size: Int64 = 0
        var contentHash: String?
        var sent: Int64 = 0
        var status: Status = .waiting
        /// Where the server filed it.
        var relativePath: String?
        var error: String?
        /// The file's size and change date when `contentHash` was taken: a
        /// file changed since (a tag edit) is hashed again before sending.
        var hashedSize: Int64?
        var hashedModified: Date?
        /// "Arrived damaged" is retried once on its own, with a fresh hash.
        var autoRetried: Bool?

        var fraction: Double { size > 0 ? Double(sent) / Double(size) : 0 }
        var folder: String { (file as NSString).deletingLastPathComponent }
    }

    /// Why nothing is being sent right now.
    enum Hold: Equatable { case paused, streaming }

    private(set) var items: [Item] = []
    /// How many files may send at once (1 or 2), as `UploadLanes` decides.
    private(set) var laneCount = 1
    /// Set while uploads wait, for Settings to say why.
    private(set) var hold: Hold?
    private(set) var isPaused = UserDefaults.standard.bool(forKey: "flactastic.server.uploadsPaused")
    /// Files uploaded or dismissed here (path → content hash). They're never
    /// queued again, even once their track is deleted on the server, and no
    /// other file with the same bytes is sent.
    @ObservationIgnored private var handled: [String: String] = [:]
    /// Local files the server already has as the same song in another
    /// format (path → the server's track): never sent, left where they are,
    /// and kept out of the library so the song shows once.
    @ObservationIgnored private(set) var duplicates: [String: UUID] = [:]
    @ObservationIgnored unowned let session: ServerSession
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var lanes = UploadLanes()
    /// Items being worked on by a lane right now.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Hashes taken ahead of time, while another file sends.
    @ObservationIgnored private var prehashing: [UUID: Task<Void, Never>] = [:]
    /// Album folders with a finished upload the library hasn't pulled yet.
    @ObservationIgnored private var unpulledFolders: Set<String> = []
    /// Whether a streamed track is playing; set by the app.
    @ObservationIgnored var isStreaming: @MainActor () -> Bool = { false }
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    init(session: ServerSession) { self.session = session }

    private var stateURL: URL? { session.active?.supportDirectory.appendingPathComponent("uploads.json") }
    private var handledURL: URL? { session.active?.supportDirectory.appendingPathComponent("uploads-handled.json") }
    private var duplicatesURL: URL? { session.active?.supportDirectory.appendingPathComponent("uploads-duplicates.json") }

    func load() {
        items = stateURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        handled = handledURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        duplicates = duplicatesURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: UUID].self, from: $0) } ?? [:]
        // Finished, or the file is gone: nothing left to do.
        items.removeAll { $0.status == .done || !FileManager.default.fileExists(atPath: $0.file) }
        for i in items.indices where items[i].status != .failed { items[i].status = .waiting }
        // "Arrived damaged" from before automatic retries: one more try each,
        // with a fresh hash.
        let damaged = ServerError.api(code: "hashMismatch", status: 422, retryAfter: nil).localizedDescription
        for i in items.indices where items[i].status == .failed && items[i].error == damaged && items[i].autoRetried != true {
            items[i].status = .waiting
            items[i].error = nil
            items[i].autoRetried = true
            items[i].contentHash = nil
        }
        // Queued before sizes were taken up front.
        for i in items.indices where items[i].size == 0 { items[i].size = Self.stamp(items[i].file)?.size ?? 0 }
        inFlight = []
        lanes = UploadLanes()
        laneCount = 1
        start()
    }

    // MARK: - Summary

    /// What's sending right now, in queue order.
    var current: [Item] { items.filter { $0.status == .sending || $0.status == .hashing } }
    var failed: [Item] { items.filter { $0.status == .failed } }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var sentBytes: Int64 { items.reduce(0) { $0 + ($1.status == .done ? $1.size : $1.sent) } }
    /// Waiting, checking or sending.
    var isBusy: Bool { items.contains { [.waiting, .hashing, .sending].contains($0.status) } }

    /// The song in a queued file, as the library read its tags; nil before
    /// they're read.
    func song(_ item: Item) -> (title: String, artist: String?)? {
        guard let track = session.localOnly[URL(fileURLWithPath: item.file).standardizedFileURL.path] else { return nil }
        return (track.title, ArtistResolver.displayString(track.artist ?? track.albumArtist))
    }

    /// Stops sending for this profile (it's closing).
    func stop() {
        running?.cancel()
        running = nil
        rescanTask?.cancel()
        rescanTask = nil
        for task in prehashing.values { task.cancel() }
        prehashing = [:]
        inFlight = []
    }

    /// The offline folder moved: queued files and the never-again list
    /// follow it, so nothing is sent twice. Runs while no profile is open.
    nonisolated static func rebasePaths(in supportDirectory: URL, from old: URL, to new: URL) {
        let oldPrefix = old.standardizedFileURL.path + "/"
        let newPrefix = new.standardizedFileURL.path + "/"
        func moved(_ path: String) -> String {
            path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path
        }
        let itemsURL = supportDirectory.appendingPathComponent("uploads.json")
        if let data = try? Data(contentsOf: itemsURL), var items = try? JSONDecoder().decode([Item].self, from: data) {
            for i in items.indices { items[i].file = moved(items[i].file) }
            if let out = try? JSONEncoder().encode(items) { try? out.write(to: itemsURL, options: .atomic) }
        }
        let handledURL = supportDirectory.appendingPathComponent("uploads-handled.json")
        if let data = try? Data(contentsOf: handledURL), let handled = try? JSONDecoder().decode([String: String].self, from: data) {
            let rebased = Dictionary(handled.map { (moved($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            if let out = try? JSONEncoder().encode(rebased) { try? out.write(to: handledURL, options: .atomic) }
        }
        let duplicatesURL = supportDirectory.appendingPathComponent("uploads-duplicates.json")
        if let data = try? Data(contentsOf: duplicatesURL), let duplicates = try? JSONDecoder().decode([String: UUID].self, from: data) {
            let rebased = Dictionary(duplicates.map { (moved($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            if let out = try? JSONEncoder().encode(rebased) { try? out.write(to: duplicatesURL, options: .atomic) }
        }
    }

    private func save() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
        if let url = handledURL, let data = try? JSONEncoder().encode(handled) { try? data.write(to: url, options: .atomic) }
        if let url = duplicatesURL, let data = try? JSONEncoder().encode(duplicates) { try? data.write(to: url, options: .atomic) }
    }

    /// Takes a file out of the queue for good; the file itself stays.
    func dismiss(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        handled[item.file] = item.contentHash ?? ""
        items.removeAll { $0.id == id }
        save()
    }

    /// Queues a file. With `replacing`, the upload replaces that track.
    func enqueue(_ url: URL, replacing trackID: UUID? = nil) {
        guard !items.contains(where: { $0.file == url.path && $0.status != .done }) else { return }
        items.append(Item(id: UUID(), file: url.path, name: url.lastPathComponent, trackID: trackID,
                          size: Self.stamp(url.path)?.size ?? 0))
        save()
        start()
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = .waiting
        items[i].error = nil
        items[i].autoRetried = nil
        save()
        start()
    }

    func pause() {
        isPaused = true
        UserDefaults.standard.set(true, forKey: "flactastic.server.uploadsPaused")
        refreshHold()
    }

    func resumeSending() {
        isPaused = false
        UserDefaults.standard.set(false, forKey: "flactastic.server.uploadsPaused")
        refreshHold()
        start()
    }

    /// The file was deleted here: nothing left to send.
    func forget(_ url: URL) {
        items.removeAll { $0.file == url.path }
        save()
    }

    func clearFinished() {
        items.removeAll { $0.status == .done }
        save()
    }

    /// Audio files in the offline folder the server doesn't have: downloads,
    /// imports, and music that was already here when this Mac signed in.
    /// Copies of server tracks, files at a server track's path, and files
    /// uploaded or dismissed before are left alone.
    func scanForNewFiles() {
        guard let profile = session.active else { return }
        let root = profile.offlineRoot
        let known = session.offline.installedPaths
        let serverPaths = session.serverTrackPaths
        let queued = Set(items.map(\.file)).union(handled.keys)
        Task.detached(priority: .utility) {
            let scan = Self.newFiles(in: root, known: known, serverPaths: serverPaths, queued: queued)
            await MainActor.run {
                Task { await self.queueUnlessOnServer(scan.ready) }
                // Still being written (a download in progress): look again soon.
                if scan.stillWriting { self.scheduleRescan(after: 15) }
            }
        }
    }

    /// Looks for new files again after `seconds`, once however often asked.
    func scheduleRescan(after seconds: Double) {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.scanForNewFiles()
        }
    }

    /// `known`: offline copies' relative paths. `serverPaths`: standardized
    /// paths of the server's tracks. `queued`: paths already queued or handled.
    /// A file changed in the last `settle` seconds is left for a later scan
    /// (`stillWriting`), so a download isn't sent half-written.
    nonisolated static func newFiles(in root: URL, known: Set<String>, serverPaths: Set<String>, queued: Set<String>,
                                     settle: TimeInterval = 10, now: Date = Date()) -> (ready: [URL], stillWriting: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        let rootPath = root.standardizedFileURL.path
        var found: [URL] = []
        var stillWriting = false
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard AudioFileFormat.classify(url) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  !queued.contains(url.path), !queued.contains(path),
                  !serverPaths.contains(path) else { continue }
            let rel = String(path.dropFirst(rootPath.count + 1))
            guard !known.contains(rel) else { continue }
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < settle {
                stillWriting = true
                continue
            }
            found.append(url)
        }
        // Album by album, in folder order, so whole albums land together.
        return (found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, stillWriting)
    }

    // MARK: - Already on the server

    /// Queues the files the server doesn't have; settles the ones it does.
    private func queueUnlessOnServer(_ urls: [URL]) async {
        let index = SongMatch.index(session.mirror.tracks.values)
        for url in urls where !(await settleIfOnServer(url.path, index: index)) {
            enqueue(url)
        }
    }

    /// A file whose song the server already has isn't sent. It becomes that
    /// track's copy here (filed where the server keeps it) only when it's
    /// provably the same recording: the same bytes, or a FLAC whose audio
    /// checksum, length and format match the server's (other tags or artwork
    /// are fine). Anything else (another rip or master, another format) stays
    /// exactly where it is, out of the library, and the server's version
    /// streams. A good copy already here wins too. True when handled.
    func settleIfOnServer(_ path: String, index: [String: [ServerTrack]]? = nil) async -> Bool {
        let url = URL(fileURLWithPath: path)
        let key = url.standardizedFileURL.path
        var local = session.localOnly[key]
        if local == nil, let stub = Track.makeFromURL(url) {
            local = await LibraryScanner().loadMetadata(for: stub)
        }
        guard let local, session.active != nil,
              let match = SongMatch.find(local, in: index ?? SongMatch.index(session.mirror.tracks.values)),
              FileManager.default.fileExists(atPath: path) else { return false }
        session.fileReachedServer(path, as: match.id)

        let verdict = session.offline.isCurrent(match.id) ? .leaveAlone : await sameRecording(url, local: local, as: match)
        switch verdict {
        case .identical(let hash):
            session.offline.adopt(uploaded: url, as: match, hash: hash)
            handled[path] = hash
        case .sameAudio(let ownHash, let serverHash):
            session.offline.adopt(uploaded: url, as: match, hash: ownHash, audioMatch: serverHash)
            handled[path] = ownHash
        case .leaveAlone:
            duplicates[path] = match.id
            handled[path] = match.contentHash ?? ""
        case .unknown:
            // Couldn't check (the server is out of reach): not sent, nothing
            // recorded, so the next scan asks again.
            return true
        }
        save()
        session.refreshLocalFiles()
        return true
    }

    enum Recording: Equatable {
        /// Byte for byte the server's file.
        case identical(hash: String)
        /// The same audio in a file of its own (other tags or artwork).
        case sameAudio(ownHash: String, serverHash: String)
        /// Not provably the same: leave the file be.
        case leaveAlone
        /// Couldn't tell right now: decide on a later scan.
        case unknown
    }

    /// Whether `url` holds the server track's recording.
    private func sameRecording(_ url: URL, local: Track, as match: ServerTrack) async -> Recording {
        // Another format (an MP3 of a FLAC) is never the same recording.
        guard AudioFileFormat(rawValue: match.format) == local.fileFormat else { return .leaveAlone }
        // The server hashes new files in the background: ask again later.
        guard let serverHash = match.contentHash else { return .unknown }
        guard let ownHash = try? await Task.detached(priority: .utility, operation: { try ContentHasher.hexDigest(ofFileAt: url) }).value
        else { return .leaveAlone }
        if ownHash == serverHash { return .identical(hash: ownHash) }
        // Lossy and other formats carry no audio checksum: only exact bytes count.
        guard local.fileFormat == .flac,
              let mine = await Task.detached(priority: .utility, operation: { FLACStreamInfo.read(fileAt: url) }).value
        else { return .leaveAlone }
        guard let client = session.client, session.status == .ready,
              let head = try? await ServerStreamer.fetch(client, match.id, 0..<Int64(FLACStreamInfo.headerBytes), nil).0
        else { return .unknown }
        guard let theirs = FLACStreamInfo.parse(head) else { return .leaveAlone }
        return Self.verdict(ownHash: ownHash, serverHash: serverHash, mine: mine, theirs: theirs, serverFrames: match.frames)
    }

    /// The rule, apart from the I/O: same audio checksum and shape, and the
    /// server's own sample count where it reports one.
    nonisolated static func verdict(ownHash: String, serverHash: String, mine: FLACStreamInfo, theirs: FLACStreamInfo,
                                    serverFrames: Int64?) -> Recording {
        if ownHash == serverHash { return .identical(hash: ownHash) }
        guard mine.isSameAudio(as: theirs) else { return .leaveAlone }
        if let frames = serverFrames, frames != mine.totalSamples { return .leaveAlone }
        return .sameAudio(ownHash: ownHash, serverHash: serverHash)
    }

    private func start() {
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.runQueue()
            self?.running = nil
        }
    }

    /// Keeps up to `laneCount` uploads going, in queue order, until nothing
    /// is waiting, the server can't be reached, or the profile closes.
    private func runQueue() async {
        await withTaskGroup(of: Bool.self) { group in
            var active = 0
            var reachable = true
            while !Task.isCancelled {
                refreshHold()
                if reachable, hold == nil, active < laneCount, let next = nextWaiting() {
                    inFlight.insert(next)
                    active += 1
                    group.addTask { await self.upload(next) }
                    continue
                }
                if active == 0 {
                    // Waiting on a hold with work queued: check again shortly.
                    if reachable, hold != nil, nextWaiting() != nil {
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    break
                }
                if hold != nil {
                    // In-flight uploads wait between chunks; keep checking.
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                if let ok = await group.next() {
                    active -= 1
                    if !ok { reachable = false }
                }
            }
        }
        await pullFinishedAlbums(force: true)
    }

    private func nextWaiting() -> UUID? {
        items.first { $0.status == .waiting && !inFlight.contains($0.id) }?.id
    }

    /// Updates `hold` from the user's pause and what's playing.
    private func refreshHold() {
        let next: Hold? = isPaused ? .paused : (isStreaming() ? .streaming : nil)
        if next != hold { hold = next }
    }

    /// Waits while uploads are held; called between chunks.
    private func waitWhileHeld() async {
        refreshHold()
        while hold != nil, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            refreshHold()
        }
    }

    /// Refreshes the library for albums whose uploads have all finished, or
    /// for every folder with a finished upload when `force`.
    private func pullFinishedAlbums(force: Bool = false) async {
        guard !unpulledFolders.isEmpty else { return }
        let busy = Set(items.filter { [.waiting, .hashing, .sending].contains($0.status) || inFlight.contains($0.id) }.map(\.folder))
        let done = force ? unpulledFolders : unpulledFolders.subtracting(busy)
        guard !done.isEmpty else { return }
        unpulledFolders.subtract(done)
        await session.pullTracks()
    }

    /// Hashes the next waiting file while another sends.
    private func prehashNext() {
        guard let item = items.first(where: { $0.status == .waiting && !inFlight.contains($0.id) && prehashing[$0.id] == nil && !Self.hashIsFresh($0) }) else { return }
        let id = item.id, path = item.file
        prehashing[id] = Task { [weak self] in
            let result = try? await Task.detached(priority: .utility) { () throws -> (String, Stamp?) in
                let stamp = Self.stamp(path)
                return (try ContentHasher.hexDigest(ofFileAt: URL(fileURLWithPath: path)), stamp)
            }.value
            guard let self else { return }
            self.prehashing[id] = nil
            if let (hash, stamp) = result, let stamp {
                self.set(id) { $0.contentHash = hash; $0.size = stamp.size; $0.hashedSize = stamp.size; $0.hashedModified = stamp.modified }
            }
        }
    }

    struct Stamp: Equatable { let size: Int64; let modified: Date }

    nonisolated static func stamp(_ path: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return nil }
        return Stamp(size: size, modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    /// Whether the stored hash still describes the file on disk.
    nonisolated static func hashIsFresh(_ item: Item) -> Bool {
        guard item.contentHash != nil, let size = item.hashedSize, let modified = item.hashedModified,
              let now = stamp(item.file) else { return false }
        return now.size == size && abs(now.modified.timeIntervalSince(modified)) < 1
    }

    /// The server is back: send what waited, and what failed only because
    /// it couldn't be reached.
    func resume() {
        let offline = ServerError.unreachable("").localizedDescription
        for i in items.indices where items[i].status == .failed && items[i].error == offline {
            items[i].status = .waiting
            items[i].error = nil
        }
        save()
        start()
    }

    private func set(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    /// False when the server couldn't be reached (the item waits).
    private func upload(_ id: UUID) async -> Bool {
        defer { inFlight.remove(id) }
        guard let client = session.client, session.status != .unreachable else { return false }
        await prehashing[id]?.value
        guard let item = items.first(where: { $0.id == id }) else { return true }
        let url = URL(fileURLWithPath: item.file)
        // The server's list caught up and this path is one of its tracks:
        // nothing to send.
        if item.trackID == nil, session.isServerTrackPath(item.file) {
            items.removeAll { $0.id == id }
            save()
            return true
        }
        // Queued before the server's list caught up: it may have the song now.
        if item.trackID == nil, await settleIfOnServer(item.file) {
            items.removeAll { $0.id == id }
            save()
            return true
        }
        do {
            var item = item
            // No hash yet, or the file changed since it was taken.
            if !Self.hashIsFresh(item) {
                set(id) { $0.status = .hashing }
                let (hash, stamp) = try await Task.detached(priority: .utility) { () throws -> (String, Stamp?) in
                    let stamp = Self.stamp(url.path)
                    return (try ContentHasher.hexDigest(ofFileAt: url), stamp)
                }.value
                item.contentHash = hash
                item.size = stamp?.size ?? 0
                item.hashedSize = stamp?.size
                item.hashedModified = stamp?.modified
                set(id) { $0.contentHash = hash; $0.size = item.size; $0.hashedSize = item.hashedSize; $0.hashedModified = item.hashedModified }
            }
            // Bytes the server already has (another copy of this file) aren't
            // sent again: this file becomes that track's copy here.
            if item.trackID == nil, let hash = item.contentHash {
                if let track = session.mirror.tracks.values.first(where: { $0.contentHash == hash }) {
                    session.fileReachedServer(item.file, as: track.id)
                    session.offline.adopt(uploaded: url, as: track, hash: hash)
                    handled[item.file] = hash
                    items.removeAll { $0.id == id }
                    save()
                    return true
                }
                if handled.values.contains(hash) {
                    handled[item.file] = hash
                    items.removeAll { $0.id == id }
                    save()
                    return true
                }
            }
            await waitWhileHeld()
            set(id) { $0.status = .sending }
            save()
            prehashNext()

            // Re-posting the same hash, size and track ID finds an open upload
            // again, so a lost upload ID costs nothing.
            struct Create: Encodable { let filename: String; let size: Int64; let contentHash: String; let trackID: UUID? }
            struct Opened: Decodable { let id: UUID; let offset: Int64 }
            let opened = try await session.call {
                try await $0.json(Opened.self, "POST", "v2/uploads",
                                  body: Create(filename: item.name, size: item.size, contentHash: item.contentHash!, trackID: item.trackID))
            }
            set(id) { $0.uploadID = opened.id; $0.sent = opened.offset }
            let began = Date()
            let track = try await Self.send(url, upload: opened.id, from: opened.offset, size: item.size, client: client,
                                            hold: { [weak self] in await self?.waitWhileHeld() }) { sent in
                self.set(id) { $0.sent = sent }
            }
            lanes.succeeded(bytes: item.size - opened.offset, seconds: Date().timeIntervalSince(began), lanesInUse: laneCount)
            laneCount = lanes.lanes
            set(id) { $0.status = .done; $0.relativePath = track.relativePath; $0.sent = $0.size }
            handled[item.file] = item.contentHash
            session.fileReachedServer(item.file, as: track.id)
            session.offline.adopt(uploaded: url, as: track, hash: track.contentHash ?? item.contentHash!)
            unpulledFolders.insert(item.folder)
            save()
            await pullFinishedAlbums()
            return true
        } catch ServerError.unreachable {
            set(id) { $0.status = .waiting }
            save()
            session.connectionLost()
            return false
        } catch is CancellationError {
            set(id) { $0.status = .waiting }
            save()
            return true
        } catch let error as ServerError {
            session.note(error)
            lanes.failed()
            laneCount = lanes.lanes
            set(id) {
                // The server deleted known-bad bytes: hash again, and once
                // without asking, try again.
                if error.code == "hashMismatch" {
                    $0.contentHash = nil; $0.hashedSize = nil; $0.hashedModified = nil; $0.uploadID = nil; $0.sent = 0
                    if $0.autoRetried != true {
                        $0.autoRetried = true
                        $0.status = .waiting
                        $0.error = nil
                        return
                    }
                }
                $0.status = .failed
                $0.error = error.localizedDescription
            }
        } catch {
            lanes.failed()
            laneCount = lanes.lanes
            set(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
        save()
        return true
    }

    /// PATCHes from `offset` until the server has every byte. A 409 or a
    /// broken connection resumes from the server's offset, never past `size`.
    nonisolated static func send(_ url: URL, upload: UUID, from offset: Int64, size: Int64, client: ServerClient,
                                 chunk: Int64 = 16 << 20, hold: @Sendable () async -> Void = {},
                                 progress: @MainActor (Int64) -> Void) async throws -> ServerTrack {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = offset, failures = 0
        while true {
            await hold()
            try Task.checkCancellation()
            let length = min(chunk, size - offset)
            try handle.seek(toOffset: UInt64(offset))
            let body = length > 0 ? (try handle.read(upToCount: Int(length)) ?? Data()) : Data()
            var request = client.request("PATCH", "v2/uploads/\(upload.uuidString)", body: body,
                                         contentType: "application/offset+octet-stream", timeout: 300)
            request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            do {
                let (data, http) = try await client.session.data(for: request)
                guard let http = http as? HTTPURLResponse else { throw ServerError.badResponse }
                switch http.statusCode {
                case 200:
                    struct Done: Decodable { let track: ServerTrack }
                    guard let done = try? ServerClient.decoder.decode(Done.self, from: data) else { throw ServerError.badResponse }
                    return done.track
                case 204, 409:
                    guard let next = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init),
                          next >= 0, next <= size else { throw ServerError.badResponse }
                    if http.statusCode == 204, next <= offset { throw ServerError.badResponse }
                    offset = next
                    failures = 0
                    await progress(next)
                default:
                    try ServerClient.check(http, body: data)
                    throw ServerError.badResponse
                }
            } catch let error as URLError {
                failures += 1
                if failures > 5 { throw client.mapTransport(error) }
                try await Task.sleep(for: .seconds(Double(failures * 2)))
                offset = try await serverOffset(upload, client: client)
                await progress(offset)
            }
        }
    }

    nonisolated private static func serverOffset(_ upload: UUID, client: ServerClient) async throws -> Int64 {
        let (_, http) = try await client.data(for: client.request("HEAD", "v2/uploads/\(upload.uuidString)"))
        guard let offset = http.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) else { throw ServerError.badResponse }
        return offset
    }
}

/// How many uploads run at once. One to start; after three clean uploads in a
/// row a second lane opens. It stays only while two lanes move clearly more
/// than one did: no gain, or any failure, drops back to one, and ten clean
/// uploads must pass before two are tried again.
struct UploadLanes: Equatable {
    private(set) var lanes = 1
    static let maxLanes = 2
    private var streak = 0
    private var cooldown = 0
    /// Bytes per second with one lane, smoothed.
    private(set) var singleLaneSpeed: Double?

    mutating func succeeded(bytes: Int64, seconds: Double, lanesInUse: Int) {
        guard seconds > 0, bytes > 0 else { return }
        let speed = Double(bytes) / seconds
        streak += 1
        if lanesInUse <= 1 {
            singleLaneSpeed = singleLaneSpeed.map { $0 * 0.5 + speed * 0.5 } ?? speed
            if cooldown > 0 { cooldown -= 1; return }
            if streak >= 3, lanes < Self.maxLanes { lanes = Self.maxLanes; streak = 0 }
        } else if let single = singleLaneSpeed, speed * Double(lanesInUse) < single * 1.15 {
            // Two at once aren't faster than one: the link or the server is the limit.
            lanes = 1
            streak = 0
            cooldown = 10
        }
    }

    mutating func failed() {
        lanes = 1
        streak = 0
        cooldown = 10
    }
}
