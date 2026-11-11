import Foundation

/// A tag edit for `PATCH /v2/tracks` (§10). Every field is three-state: a
/// key that's absent leaves the tag alone, `null` clears it, a value sets it.
struct TagEdit: Encodable, Hashable, Sendable {
    var fields: [String: JSONValue] = [:]

    var isEmpty: Bool { fields.isEmpty }

    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }

    /// A cover the server takes in an edit (§17: ≤ 10 MiB, ≤ 6000 px a
    /// side): as is when it fits, else a JPEG at the same size, smaller
    /// steps of quality until it does.
    static func fitForServer(_ data: Data) -> Data {
        let limit = 10 << 20
        // At 0.9, `fit` keeps a picture within 6000 px untouched.
        for quality in [0.9, 0.8, 0.65, 0.5] {
            let out = ArtistProfileFile.fit(data, edge: 6000, quality: quality)
            if out.count <= limit { return out }
        }
        return data
    }

    mutating func text(_ key: String, _ old: String?, _ new: String?) {
        let o = old ?? "", n = new ?? ""
        guard o != n else { return }
        fields[key] = n.isEmpty ? .null : .string(n)
    }

    mutating func number(_ key: String, _ old: Int?, _ new: Int?) {
        guard old != new else { return }
        fields[key] = new.map(JSONValue.int) ?? .null
    }

    mutating func flag(_ key: String, _ old: Bool, _ new: Bool) {
        guard old != new else { return }
        fields[key] = .bool(new)
    }

    /// The edit for the values `MetadataWriter.write` was given, against what
    /// the track holds now. Only what differs is sent.
    static func from(
        _ t: Track, title: String, artist: String?, album: String?, year: Int?, genre: String?,
        secondaryGenres: [String], trackNumber: Int?, artwork: MetadataWriter.ArtworkChange,
        albumArtist: MetadataWriter.AlbumArtistChange, compilation: MetadataWriter.CompilationChange,
        mix: MetadataWriter.MixCompilationChange, label: MetadataWriter.LabelChange,
        disc: MetadataWriter.DiscChange
    ) -> TagEdit {
        var e = TagEdit()
        e.text("title", t.title, title)
        e.text("artist", t.artist, artist)
        e.text("album", t.album, album)
        e.number("year", t.year, year)
        e.text("genre", t.genre, genre)
        if t.secondaryGenres != secondaryGenres { e.fields["secondaryGenres"] = .array(secondaryGenres.map(JSONValue.string)) }
        e.number("trackNumber", t.trackNumber, trackNumber)
        if case .set(let v) = albumArtist { e.text("albumArtist", t.albumArtist, v) }
        if case .set(let on) = compilation { e.flag("isCompilation", t.isCompilation, on) }
        if case .set(let on) = mix { e.flag("isMixCompilation", t.isMixCompilation, on) }
        if case .set(let v) = label { e.text("label", t.label, v) }
        if case .set(let number, let total) = disc {
            e.number("discNumber", t.discNumber, number)
            e.number("discTotal", t.discTotal, total)
        }
        switch artwork {
        case .unchanged: break
        case .removed: if t.artwork != nil || t.artworkID != nil { e.fields["artwork"] = .null }
        case .updated(let data): e.fields["artwork"] = .string(Self.fitForServer(data).base64EncodedString())
        }
        return e
    }
}

/// Sends tag edits to the server for a server profile. `MetadataWriter`
/// routes the editors' writes here.
final class ServerTagEditor: Sendable {
    let client: ServerClient
    let root: URL
    /// Resolves a played track to its server ID (queued copies carry fresh IDs).
    private let streamer: ServerStreamer?
    /// Told about every track the server returns, to refresh the mirror and library.
    private let onApplied: (@Sendable ([ServerTrack]) -> Void)?

    init(client: ServerClient, root: URL, streamer: ServerStreamer? = nil,
         onApplied: (@Sendable ([ServerTrack]) -> Void)? = nil) {
        self.client = client
        self.root = root
        self.streamer = streamer
        self.onApplied = onApplied
    }

    /// The server has this track. A file here it doesn't have yet (an
    /// import waiting to upload) is tagged on this Mac.
    func knows(_ track: Track) -> Bool {
        streamer?.config.withLock { $0.tracks[track.url.standardizedFileURL.path] != nil } ?? true
    }

    /// A verified offline copy is on this Mac: its tags can be read from it.
    func hasCurrentCopy(_ track: Track) -> Bool {
        let id = serverID(track)
        return streamer?.config.withLock { $0.offline.contains(id) } == true
            && FileManager.default.fileExists(atPath: track.url.path)
    }

    func serverID(_ track: Track) -> UUID {
        streamer?.config.withLock { $0.tracks[track.url.standardizedFileURL.path]?.id } ?? track.id
    }

    /// Applies `edit` and returns the track as the server now has it; it may
    /// have been refiled to a new path by the Organizer profile.
    func apply(_ edit: TagEdit, to track: Track) async throws -> Track {
        guard !edit.isEmpty else { return track }
        struct One: Decodable { let track: ServerTrack }
        let result = try await client.json(One.self, "PATCH", "v2/tracks/\(serverID(track).uuidString)", body: edit)
        onApplied?([result.track])
        return carry(result.track, from: track, edit: edit)
    }

    /// One edit for many tracks: an album edit (`PATCH /v2/tracks`, ≤ 1000).
    func apply(_ edit: TagEdit, to tracks: [Track]) async throws -> [Track] {
        guard !edit.isEmpty, !tracks.isEmpty else { return tracks }
        struct Batch: Encodable { let ids: [UUID]; let edit: TagEdit }
        struct Many: Decodable { let tracks: [ServerTrack] }
        let byID = Dictionary(tracks.map { (serverID($0), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Track] = []
        for start in stride(from: 0, to: tracks.count, by: 1000) {
            let slice = tracks[start..<min(start + 1000, tracks.count)]
            let result = try await client.json(Many.self, "PATCH", "v2/tracks", body: Batch(ids: slice.map(serverID), edit: edit))
            onApplied?(result.tracks)
            out += result.tracks.compactMap { s in byID[s.id].map { carry(s, from: $0, edit: edit) } }
        }
        return out
    }

    func detail(_ track: Track) async throws -> ServerTrack {
        try await client.json(ServerTrack.self, "GET", "v2/tracks/\(serverID(track).uuidString)")
    }

    /// The app's track for a server reply, keeping the cover bytes it had
    /// (or the ones just sent) until the next mirror pull fetches the new one.
    private func carry(_ server: ServerTrack, from old: Track, edit: TagEdit) -> Track {
        var t = server.appTrack(root: root) ?? old
        switch edit.fields["artwork"] {
        case .string(let b64)?: t.artwork = Data(base64Encoded: b64)
        case .null?: t.artwork = nil
        default: t.artwork = old.artwork
        }
        return t
    }
}
