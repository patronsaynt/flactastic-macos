import Foundation

enum CollectionSortOption: String, CaseIterable, Identifiable {
    case album = "Album"
    case artist = "Artist"
    case year = "Year"
    case genre = "Genre"

    var id: String { rawValue }
}

/// Sort for the Artists lineup.
enum ArtistSortOption: String, CaseIterable, Identifiable {
    /// Headliners first: most albums and singles, then A to Z.
    case mostReleases = "Most Releases"
    /// Most played first, by counted plays across every track they're
    /// credited on, then by time listened.
    case mostListens = "Most Listens"
    case name = "A–Z"

    var id: String { rawValue }
}

/// How the Albums section shows: the stacked shelf, or a cover grid.
enum AlbumViewStyle: String, CaseIterable, Identifiable {
    case shelf
    case grid

    var id: String { rawValue }
}
