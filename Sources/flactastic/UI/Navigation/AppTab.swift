import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case collection = "Collection"
    case playlists = "Playlists"
    case download = "Download"
    case organizer = "Organizer"
    case visualizer = "Visualizer"

    var id: String { rawValue }
}
