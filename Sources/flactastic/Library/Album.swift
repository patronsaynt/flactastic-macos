import Foundation

struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let albumArtist: String?
    let year: Int?
    let genre: String?
    /// The record label, from the first track that carries one.
    var label: String? = nil
    let secondaryGenres: [String]
    let artwork: Data?
    let tracks: [Track]

    var trackCount: Int { tracks.count }
    var totalDuration: TimeInterval {
        tracks.compactMap(\.duration).reduce(0, +)
    }
    /// True when any track in the album carries the COMPILATION tag. The flag
    /// is per-track in the file format, so users editing through FLACtastic's
    /// album editor get an all-or-nothing toggle that writes every track.
    var isCompilation: Bool {
        tracks.contains(where: \.isCompilation)
    }
    /// True when any track in the album is a Mix Compilation (a DJ mix, live
    /// set, radio show, or concert recording). Surfaced in the album's
    /// metadata line so it reads clearly even for single-track imports.
    var isMixCompilation: Bool {
        tracks.contains(where: \.isMixCompilation)
    }
    /// A single or EP rather than an album: fewer than three tracks. Artist
    /// pages list these apart, and the Albums view can leave them out.
    var isSingle: Bool { tracks.count < 3 }

    /// The tracks split by disc, in disc order, for albums whose tracks span
    /// more than one disc number. Empty for a single-disc album, which reads
    /// as one plain list. Untagged tracks count as disc 1.
    var discs: [(number: Int, tracks: [Track])] {
        let numbers = Set(tracks.map { $0.discNumber ?? 1 })
        guard numbers.count > 1 else { return [] }
        return Dictionary(grouping: tracks) { $0.discNumber ?? 1 }
            .sorted { $0.key < $1.key }
            .map { (number: $0.key, tracks: $0.value) }
    }
}
