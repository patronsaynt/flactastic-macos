import Foundation

struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let albumArtist: String?
    let year: Int?
    let genre: String?
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
}
