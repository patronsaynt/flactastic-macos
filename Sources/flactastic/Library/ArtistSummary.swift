import Foundation

/// Aggregated view of one artist: their own releases (split into albums vs
/// singles/EPs by track count) plus albums they appear on as a guest credit.
struct ArtistSummary: Identifiable, Sendable {
    let id: String              // canonical key from ArtistResolver
    let displayName: String
    let albums: [Album]
    let singles: [Album]
    let appearsOn: [Album]
    /// Only the tracks this artist is credited on from `appearsOn` albums,
    /// in album order — a guest spot shouldn't pull in the rest of the album.
    let appearsOnTracks: [Track]
    let trackCount: Int
    let artworkSample: Data?

    /// Everything "play / shuffle this artist" should queue: every track of
    /// their own albums and singles, plus just their credited tracks from the
    /// albums they appear on.
    var playableTracks: [Track] {
        (albums + singles).flatMap(\.tracks) + appearsOnTracks
    }
}
