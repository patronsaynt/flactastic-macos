import Foundation
import Observation

/// Offline copies of any part of a server library (§13): the user picks
/// albums, playlists or everything, the server sends a manifest, v1's
/// `SyncDiff` decides what to fetch, and each file is downloaded with ranged
/// requests, verified against `contentHash` and installed atomically.
@Observable
@MainActor
final class OfflineCopies {
    struct Selection: Codable, Equatable {
        var everything = false
        var albumIDs: Set<String> = []
        var playlistIDs: Set<UUID> = []
        var filter = SyncFilter()
    }

    /// A copy on disk, as the server described it when it was installed.
    struct Installed: Codable {
        var relativePath: String
        var contentHash: String
        var tagFingerprint: String
        var fileSize: Int64
        var format: AudioFileFormat
        /// Kept after an upload rather than chosen; never removed by a refresh.
        var kept = false
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var bytesDone: Int64
        var bytesTotal: Int64
    }

    private(set) var selection = Selection()
    private(set) var installed: [UUID: Installed] = [:]
    private(set) var progress: Progress?
    /// Tracks in the selection the server hasn't hashed yet (§13).
    private(set) var pending = 0
    private(set) var lastError: String?

    @ObservationIgnored unowned let session: ServerSession
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var again = false

    init(session: ServerSession) { self.session = session }

    var usedBytes: Int64 { installed.values.reduce(0) { $0 + $1.fileSize } }
    var isEmpty: Bool { !selection.everything && selection.albumIDs.isEmpty && selection.playlistIDs.isEmpty }

    /// Installed and identical to what the server has now.
    func isCurrent(_ id: UUID) -> Bool {
        guard let copy = installed[id], let hash = session.mirror.tracks[id]?.contentHash else { return false }
        return copy.contentHash == hash
    }

    func isKept(album id: String) -> Bool { selection.everything || selection.albumIDs.contains(id) }
    func isKept(playlist id: UUID) -> Bool { selection.everything || selection.playlistIDs.contains(id) }

    // MARK: - Persistence

    private var dir: URL? { session.active?.supportDirectory }

    func load() {
        selection = dir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("offline.json")) }
            .flatMap { try? JSONDecoder().decode(Selection.self, from: $0) } ?? Selection()
        installed = dir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("offline-index.json")) }
            .flatMap { try? JSONDecoder().decode([UUID: Installed].self, from: $0) } ?? [:]
        progress = nil
        lastError = nil
        publish()
    }

    private func saveSelection() {
        guard let dir, let data = try? JSONEncoder().encode(selection) else { return }
        try? data.write(to: dir.appendingPathComponent("offline.json"), options: .atomic)
    }

    private func saveIndex() {
        guard let dir, let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: dir.appendingPathComponent("offline-index.json"), options: .atomic)
    }

    /// Tells the player which copies it may play instead of streaming.
    private func publish() {
        let current = Set(installed.keys.filter(isCurrent))
        session.streamer.config.withLock { $0.offline = current }
    }

    // MARK: - Choosing

    func setEverything(_ on: Bool) { update { $0.everything = on } }
    func setFilter(_ filter: SyncFilter) { update { $0.filter = filter } }
    func setAlbum(_ id: String, kept: Bool) { update { if kept { $0.albumIDs.insert(id) } else { $0.albumIDs.remove(id) } } }
    func setPlaylist(_ id: UUID, kept: Bool) { update { if kept { $0.playlistIDs.insert(id) } else { $0.playlistIDs.remove(id) } } }

    private func update(_ change: (inout Selection) -> Void) {
        change(&selection)
        saveSelection()
        refresh()
    }

    /// The server reported track or playlist changes.
    func libraryChanged() {
        publish()
        if !isEmpty || installed.values.contains(where: { !$0.kept }) { refresh() }
    }

    // MARK: - Refreshing

    func refresh() {
        guard refreshTask == nil else { again = true; return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.again = false
                await self.run()
            } while self.again && !Task.isCancelled
            self.refreshTask = nil
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        progress = nil
    }

    private func run() async {
        guard let profile = session.active, let client = session.client else { return }
        let root = profile.offlineRoot
        lastError = nil

        var incoming = LibraryManifest(deviceID: profile.serverID, tracks: [], playlists: [])
        if !isEmpty {
            do {
                (incoming, pending) = try await manifest(client)
            } catch let error as ServerError {
                session.note(error)
                lastError = error.localizedDescription
                return
            } catch {
                return
            }
        } else {
            pending = 0
        }

        // Copies the server moved (the Organizer, a tag edit) move here too;
        // a copy matching by content under another ID adopts the server's.
        let byHash = Dictionary(installed.map { ($0.value.contentHash, $0.key) }, uniquingKeysWith: { a, _ in a })
        for entry in incoming.tracks {
            if let copy = installed[entry.trackID] {
                if copy.contentHash == entry.contentHash, copy.relativePath != entry.relativePath {
                    relocate(entry.trackID, to: entry, root: root)
                }
            } else if let other = byHash[entry.contentHash], let copy = installed[other] {
                installed[other] = nil
                installed[entry.trackID] = copy
                relocate(entry.trackID, to: entry, root: root)
            }
        }

        let local = LibraryManifest(deviceID: profile.id, tracks: installed.map { id, c in
            TrackManifestEntry(trackID: id, relativePath: c.relativePath, fileSize: c.fileSize, contentHash: c.contentHash,
                               format: c.format, tagFingerprint: c.tagFingerprint, title: "", artist: nil, album: nil)
        }, playlists: [])
        let plan = SyncDiff.plan(incoming: incoming, local: local, direction: .pull, filter: selection.filter)

        // No longer chosen: the app's own copies go; kept uploads stay.
        let wanted = Set(incoming.tracks.map(\.trackID))
        for (id, copy) in installed where !wanted.contains(id) && !copy.kept {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(copy.relativePath))
            installed[id] = nil
        }
        saveIndex()
        publish()

        var todo = plan.allIncomingTracks
        if let cap = selection.filter.maxTotalTransferBytes {
            var total: Int64 = 0
            todo = todo.filter { total += $0.fileSize; return total <= cap }
        }
        guard !todo.isEmpty else { progress = nil; return }
        progress = Progress(done: 0, total: todo.count, bytesDone: 0, bytesTotal: todo.reduce(0) { $0 + $1.fileSize })
        for entry in todo {
            guard !Task.isCancelled, session.active?.id == profile.id else { break }
            do {
                try await download(entry, client: client, root: root)
                progress?.done += 1
                progress?.bytesDone += entry.fileSize
                publish()
            } catch let error as ServerError {
                session.note(error)
                lastError = error.localizedDescription
                if case .unreachable = error { break }
                if error == .identityChanged { break }
            } catch {
                lastError = error.localizedDescription
            }
        }
        progress = nil
        FileTransfer.sweepAbandonedPartFiles(libraryRoot: root)
    }

    private func manifest(_ client: ServerClient) async throws -> (LibraryManifest, Int) {
        struct Pick: Encodable { let albumIDs: [String]?; let playlistIDs: [UUID]? }
        struct Request: Encodable { let selection: Pick?; let filter: SyncFilter }
        let pick = selection.everything ? nil : Pick(
            albumIDs: selection.albumIDs.isEmpty ? nil : Array(selection.albumIDs),
            playlistIDs: selection.playlistIDs.isEmpty ? nil : Array(selection.playlistIDs))
        let body = try ServerClient.encoder.encode(Request(selection: pick, filter: selection.filter))
        let (data, http) = try await client.data(for: client.request("POST", "v2/manifest", body: body))
        guard let manifest = try? ServerClient.decoder.decode(LibraryManifest.self, from: data) else { throw ServerError.badResponse }
        return (manifest, http.value(forHTTPHeaderField: "FLACtastic-Pending").flatMap { Int($0) } ?? 0)
    }

    /// Ranged download into a `.part`, resumed from its length; verified
    /// against `contentHash` (a mismatch deletes it), then installed
    /// atomically with the server's `trackID` written to the file.
    private func download(_ entry: TrackManifestEntry, client: ServerClient, root: URL) async throws {
        let fm = FileManager.default
        let destination = try PathSanitizer.destinationForIncomingTrack(remoteRelativePath: entry.relativePath, under: root)
        let incomingDir = root.appendingPathComponent(".flactastic/incoming", isDirectory: true)
        try fm.createDirectory(at: incomingDir, withIntermediateDirectories: true)
        let part = incomingDir.appendingPathComponent("\(entry.trackID.uuidString).part")

        var have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? nil ?? 0
        if have > entry.fileSize { try? fm.removeItem(at: part); have = 0 }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        let handle = try FileHandle(forWritingTo: part)
        var etag: String? = "\"sha256:\(entry.contentHash)\""
        do {
            while have < entry.fileSize {
                try Task.checkCancellation()
                let (data, partial, tag) = try await ServerStreamer.fetch(client, entry.trackID, have..<min(have + (8 << 20), entry.fileSize), etag)
                if !partial { try handle.truncate(atOffset: 0); have = 0 }
                etag = tag
                try handle.seek(toOffset: UInt64(have))
                try handle.write(contentsOf: data)
                have += Int64(data.count)
                if data.isEmpty { throw ServerError.badResponse }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let digest = try await Task.detached(priority: .utility) { try ContentHasher.hexDigest(ofFileAt: part) }.value
        guard ContentHasher.digestsMatch(digest, entry.contentHash) else {
            try? fm.removeItem(at: part)
            throw ServerError.api(code: "hashMismatch", status: 422, retryAfter: nil)
        }
        Self.writeTrackID(entry.trackID, to: part)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: part)
        } else {
            try fm.moveItem(at: part, to: destination)
        }
        if let old = installed[entry.trackID], old.relativePath != entry.relativePath {
            try? fm.removeItem(at: root.appendingPathComponent(old.relativePath))
        }
        installed[entry.trackID] = Installed(
            relativePath: entry.relativePath, contentHash: entry.contentHash, tagFingerprint: entry.tagFingerprint,
            fileSize: entry.fileSize, format: entry.format, kept: installed[entry.trackID]?.kept ?? false)
        saveIndex()
    }

    private func relocate(_ id: UUID, to entry: TrackManifestEntry, root: URL) {
        guard var copy = installed[id],
              let destination = try? PathSanitizer.destinationForIncomingTrack(remoteRelativePath: entry.relativePath, under: root) else { return }
        let fm = FileManager.default
        let source = root.appendingPathComponent(copy.relativePath)
        if source.standardizedFileURL != destination.standardizedFileURL {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? fm.moveItem(at: source, to: destination)) != nil else { installed[id] = nil; return }
        }
        Self.writeTrackID(id, to: destination)
        copy.relativePath = entry.relativePath
        copy.tagFingerprint = entry.tagFingerprint
        installed[id] = copy
    }

    /// An uploaded file stays as an offline copy, filed where the server put it.
    /// `hash` is the one the upload was checked against: a new track's
    /// reply has none until the server hashes it in the background.
    func adopt(uploaded file: URL, as track: ServerTrack, hash: String) {
        guard let root = session.active?.offlineRoot,
              let format = AudioFileFormat(rawValue: track.format),
              let destination = try? PathSanitizer.destinationForIncomingTrack(remoteRelativePath: track.relativePath, under: root)
        else { return }
        let fm = FileManager.default
        if file.standardizedFileURL != destination.standardizedFileURL {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: file) }
                else { try fm.moveItem(at: file, to: destination) }
            } catch { return }
        }
        Self.writeTrackID(track.id, to: destination)
        installed[track.id] = Installed(relativePath: track.relativePath, contentHash: hash, tagFingerprint: track.tagFingerprint,
                                        fileSize: track.fileSize, format: format, kept: true)
        saveIndex()
        publish()
    }

    /// The paths the index covers, for telling new files from copies.
    var installedPaths: Set<String> { Set(installed.values.map(\.relativePath)) }

    /// Removes one copy the user no longer wants on this Mac.
    func remove(_ id: UUID) {
        guard let root = session.active?.offlineRoot, let copy = installed[id] else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(copy.relativePath))
        installed[id] = nil
        saveIndex()
        publish()
    }

    /// The track was deleted: its copy here goes to the Trash.
    func trash(_ id: UUID) {
        guard let root = session.active?.offlineRoot, let copy = installed[id] else { return }
        try? FileManager.default.trashItem(at: root.appendingPathComponent(copy.relativePath), resultingItemURL: nil)
        installed[id] = nil
        saveIndex()
        publish()
    }

    nonisolated static func writeTrackID(_ id: UUID, to url: URL) {
        _ = id.uuidString.withCString { setxattr(url.path, "com.flactastic.trackID", $0, strlen($0), 0, 0) }
    }
}
