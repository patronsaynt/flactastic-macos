import Foundation

/// Aggregated view of one artist: their own releases (split into albums vs
/// singles/EPs by track count) plus albums they appear on as a guest credit.
struct ArtistSummary: Identifiable, Sendable {
    let id: String              // canonical key from ArtistResolver
    let displayName: String
    let albums: [Album]
    let singles: [Album]
    let appearsOn: [Album]
    let trackCount: Int
    let artworkSample: Data?
}
