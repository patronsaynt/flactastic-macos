import Foundation
import CryptoKit

/// SHA-256 helpers shared by the manifest, the transfer verifier, and the tag
/// fingerprint.
///
/// Files are hashed by streaming rather than `Data(contentsOf:)`: a library can
/// contain multi-hundred-megabyte FLAC transfers, and on iOS the library lives
/// in the app container where a whole-file read is a real memory-pressure
/// hazard.
enum ContentHasher {

    /// Chunk size for streamed hashing. Matches the transfer chunk so a file
    /// can be hashed and sent by the same read loop later if that becomes
    /// worthwhile.
    static let readChunkBytes = SyncProtocol.fileChunkBytes

    static func hexDigest(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Streams `url` and returns its lowercase hex SHA-256.
    ///
    /// Cooperatively cancellable — hashing a whole library is the slowest part
    /// of building a manifest, and the user can leave the Sync screen at any
    /// point during it.
    static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: readChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// Constant-time comparison of two hex digests.
    ///
    /// Timing is not a practical concern for a hash the peer already knows, but
    /// verification results gate whether a file enters the library, and making
    /// every comparison of attacker-influenced material constant-time is
    /// cheaper than reasoning about which ones matter.
    static func digestsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds the `tagFingerprint` carried in `TrackManifestEntry`.
///
/// The fingerprint answers one question: "would syncing this file change the
/// metadata the user sees?" So it covers exactly the tags FLACtastic writes and
/// displays, in a fixed order, with normalisation applied so that cosmetic
/// differences — trailing whitespace, a `nil` versus an empty string — do not
/// manufacture a conflict the user then has to click through.
///
/// `isMixCompilation` is macOS-only — the iOS port has no metadata writer and
/// no such field, so it passes `nil`. The digest therefore treats **absent and
/// false as the same thing**, appending the field only when it is true. Any
/// other rule would make a Mac (sending `false`) and an iPhone (sending `nil`)
/// disagree on the fingerprint of every single track, turning an entire
/// cross-platform library into one long list of phantom conflicts.
///
/// This is the general rule for extending the fingerprint: a new field must be
/// appended at the end *and* must contribute nothing in its default state, so
/// that a peer which has never heard of it still computes the same digest.
enum TagFingerprint {

    static func compute(
        title: String,
        artist: String?,
        albumArtist: String?,
        album: String?,
        trackNumber: Int?,
        genre: String?,
        secondaryGenres: [String],
        year: Int?,
        isCompilation: Bool,
        isMixCompilation: Bool? = nil
    ) -> String {
        // Field order is part of the wire contract — never reorder or insert
        // in the middle. Append new fields at the end so older peers, which
        // simply won't send them, stay comparable for unaffected tracks.
        var fields: [String] = [
            normalise(title),
            normalise(artist),
            normalise(albumArtist),
            normalise(album),
            trackNumber.map(String.init) ?? "",
            normalise(genre),
            // Secondary genres are a set in meaning but an array in storage;
            // sort so two libraries that added them in different orders agree.
            secondaryGenres.map(normalise).sorted().joined(separator: ","),
            year.map(String.init) ?? "",
            isCompilation ? "1" : "0",
        ]
        // Only contributes when true — see the note above on absent-equals-false.
        if isMixCompilation == true { fields.append("mix") }

        // Unit separator: cannot appear in a tag, so no field value can forge
        // a boundary and collide with a different set of tags.
        return ContentHasher.hexDigest(of: Data(fields.joined(separator: "\u{1F}").utf8))
    }

    static func compute(for track: Track) -> String {
        compute(
            title: track.title,
            artist: track.artist,
            albumArtist: track.albumArtist,
            album: track.album,
            trackNumber: track.trackNumber,
            genre: track.genre,
            secondaryGenres: track.secondaryGenres,
            year: track.year,
            isCompilation: track.isCompilation,
            isMixCompilation: track.isMixCompilation
        )
    }

    /// Human-readable list of which tags differ, for the conflict sheet.
    /// Purely presentational — the fingerprint alone decides *whether* there
    /// is a conflict.
    static func differingFields(between lhs: Track, and rhs: TrackManifestEntry) -> [String] {
        var differences: [String] = []
        if normalise(lhs.title) != normalise(rhs.title)   { differences.append("Title") }
        if normalise(lhs.artist) != normalise(rhs.artist) { differences.append("Artist") }
        if normalise(lhs.album) != normalise(rhs.album)   { differences.append("Album") }
        return differences
    }

    private static func normalise(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
