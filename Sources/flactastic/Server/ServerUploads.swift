import Foundation
import Observation

/// Sends files into the server library (§9.4): hash, `POST`, `PATCH` in
/// 16 MiB chunks from the server's offset, resuming after any break. The
/// server files each upload with the selected Organizer profile; the file
/// then stays here as an offline copy at that path.
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

        var fraction: Double { size > 0 ? Double(sent) / Double(size) : 0 }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored unowned let session: ServerSession
    @ObservationIgnored private var running: Task<Void, Never>?

    init(session: ServerSession) { self.session = session }

    private var stateURL: URL? { session.active?.supportDirectory.appendingPathComponent("uploads.json") }

    func load() {
        items = stateURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        items.removeAll { $0.status == .done }
        for i in items.indices where items[i].status != .failed { items[i].status = .waiting }
        start()
    }

    private func save() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Queues a file. With `replacing`, the upload replaces that track.
    func enqueue(_ url: URL, replacing trackID: UUID? = nil) {
        guard !items.contains(where: { $0.file == url.path && $0.status != .done }) else { return }
        items.append(Item(id: UUID(), file: url.path, name: url.lastPathComponent, trackID: trackID))
        save()
        start()
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = .waiting
        items[i].error = nil
        save()
        start()
    }

    func clearFinished() {
        items.removeAll { $0.status == .done }
        save()
    }

    /// Audio files that arrived in the offline folder since the profile was
    /// made (downloads, imports) and aren't copies of server tracks.
    func scanForNewFiles() {
        guard let profile = session.active else { return }
        let root = profile.offlineRoot
        let known = session.offline.installedPaths
        let since = profile.created
        let queued = Set(items.map(\.file))
        Task.detached(priority: .utility) {
            let found = Self.newFiles(in: root, since: since, known: known, queued: queued)
            await MainActor.run { for url in found { self.enqueue(url) } }
        }
    }

    nonisolated private static func newFiles(in root: URL, since: Date, known: Set<String>, queued: Set<String>) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var found: [URL] = []
        for case let url as URL in walker {
            guard AudioFileFormat.classify(url) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.creationDate ?? .distantPast) >= since,
                  !queued.contains(url.path) else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            if !known.contains(rel) { found.append(url) }
        }
        return found
    }

    private func start() {
        guard running == nil else { return }
        running = Task { [weak self] in
            while let self, let i = self.items.firstIndex(where: { $0.status == .waiting }), !Task.isCancelled {
                await self.upload(self.items[i].id)
            }
            self?.running = nil
        }
    }

    private func set(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func upload(_ id: UUID) async {
        guard let client = session.client, let item = items.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: item.file)
        do {
            var item = item
            if item.contentHash == nil {
                set(id) { $0.status = .hashing }
                item.contentHash = try await Task.detached(priority: .utility) { try ContentHasher.hexDigest(ofFileAt: url) }.value
                item.size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                set(id) { $0.contentHash = item.contentHash; $0.size = item.size }
            }
            set(id) { $0.status = .sending }
            save()

            // Re-posting the same hash, size and track ID finds an open upload
            // again, so a lost upload ID costs nothing.
            struct Create: Encodable { let filename: String; let size: Int64; let contentHash: String; let trackID: UUID? }
            struct Opened: Decodable { let id: UUID; let offset: Int64 }
            let opened = try await session.call {
                try await $0.json(Opened.self, "POST", "v2/uploads",
                                  body: Create(filename: item.name, size: item.size, contentHash: item.contentHash!, trackID: item.trackID))
            }
            set(id) { $0.uploadID = opened.id; $0.sent = opened.offset }
            let track = try await Self.send(url, upload: opened.id, from: opened.offset, size: item.size, client: client) { sent in
                self.set(id) { $0.sent = sent }
            }
            set(id) { $0.status = .done; $0.relativePath = track.relativePath; $0.sent = $0.size }
            session.offline.adopt(uploaded: url, as: track)
            await session.pullTracks()
        } catch let error as ServerError {
            session.note(error)
            set(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
                // The server deleted known-bad bytes: hash again next time.
                if error.code == "hashMismatch" { $0.contentHash = nil; $0.uploadID = nil; $0.sent = 0 }
            }
        } catch {
            set(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
        save()
    }

    /// PATCHes from `offset` until the server has every byte. A 409 or a
    /// broken connection resumes from the server's offset, never past `size`.
    nonisolated static func send(_ url: URL, upload: UUID, from offset: Int64, size: Int64, client: ServerClient,
                                 chunk: Int64 = 16 << 20, progress: @MainActor (Int64) -> Void) async throws -> ServerTrack {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = offset, failures = 0
        while true {
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
