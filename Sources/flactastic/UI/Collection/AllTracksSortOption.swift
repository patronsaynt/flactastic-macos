import Foundation

/// Sort options for the flat "All Tracks" view in the Collection tab.
enum AllTracksSortOption: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case songName = "Song Name"
    case artistName = "Artist"
    case fidelity = "Fidelity"

    /// The direction a sort starts in when chosen: newest first for date
    /// added, best first for fidelity, A to Z otherwise.
    var defaultAscending: Bool {
        switch self {
        case .dateAdded, .fidelity: return false
        case .songName, .artistName: return true
        }
    }

    var id: String { rawValue }
}

/// Mode switch on the Collection page: browse albums (existing behaviour) or
/// see the entire catalogue as a flat sortable track list.
enum CollectionContentMode: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case artists = "Artists"
    case tracks = "Tracks"

    var id: String { rawValue }
}
