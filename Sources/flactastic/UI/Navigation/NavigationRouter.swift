import Foundation
import Observation

@Observable
@MainActor
final class NavigationRouter {
    var selectedTab: AppTab = .home {
        didSet {
            // A manual tab switch abandons any "return to where I came from"
            // context; programmatic jumps set `isJumping` to keep it.
            if !isJumping, selectedTab != oldValue { returnStack.removeAll() }
        }
    }
    var collectionPath: [String] = []
    /// Navigation stack for the Playlists tab, driven so the Home page can deep-
    /// link straight to a playlist's detail view.
    var playlistsPath: [UUID] = []
    var artworkZoomData: Data? = nil

    /// Where a cross-tab jump started, so Back can return there instead of
    /// popping to the destination tab's root.
    private struct ReturnPoint {
        let tab: AppTab
        let collectionPath: [String]
        let playlistsPath: [UUID]
        /// Destination tab and its path depth right after the jump. Back only
        /// restores this point when popping from exactly that depth.
        let destinationTab: AppTab
        let entryDepth: Int
    }
    private var returnStack: [ReturnPoint] = []
    private var isJumping = false

    private func recordReturnPoint(destination: AppTab, entryDepth: Int) -> ReturnPoint {
        ReturnPoint(tab: selectedTab, collectionPath: collectionPath, playlistsPath: playlistsPath,
                    destinationTab: destination, entryDepth: entryDepth)
    }

    func navigateToAlbum(id: String) {
        if selectedTab == .collection {
            // Already in the stack: push, so Back returns to the current page.
            if collectionPath.last != id { collectionPath.append(id) }
            return
        }
        let point = recordReturnPoint(destination: .collection, entryDepth: 1)
        // Pop any current album, switch tabs, then push the new one on the
        // next runloop tick. Doing the push in one step caused the previously
        // open album to flash on screen first when the NavigationStack
        // reused its existing detail view for a same-length path swap.
        collectionPath = []
        jump(to: .collection, point: point)
        DispatchQueue.main.async {
            self.collectionPath = [id]
        }
    }

    /// Switch to the Playlists tab and open the given playlist's detail view.
    func navigateToPlaylist(id: UUID) {
        if selectedTab == .playlists {
            if playlistsPath.last != id { playlistsPath.append(id) }
            return
        }
        let point = recordReturnPoint(destination: .playlists, entryDepth: 1)
        playlistsPath = []
        jump(to: .playlists, point: point)
        DispatchQueue.main.async {
            self.playlistsPath = [id]
        }
    }

    /// Push an artist detail page. Encoded as `"artist:<canonicalKey>"` so it
    /// flows through the existing String-typed navigation stack alongside
    /// album IDs.
    func navigateToArtist(key: String) {
        let value = NavigationRoute.artist(key: key)
        if selectedTab != .collection {
            let point = recordReturnPoint(destination: .collection, entryDepth: collectionPath.count + 1)
            jump(to: .collection, point: point)
        }
        if collectionPath.last == value { return }
        collectionPath.append(value)
    }

    private func jump(to tab: AppTab, point: ReturnPoint) {
        isJumping = true
        returnStack.append(point)
        selectedTab = tab
        isJumping = false
    }

    /// Back from a Collection-tab detail page.
    func goBackInCollection() {
        guard !collectionPath.isEmpty else { return }
        if restoreReturnPoint(tab: .collection, depth: collectionPath.count) { return }
        collectionPath.removeLast()
    }

    /// Back from a Playlists-tab detail page.
    func goBackInPlaylists() {
        guard !playlistsPath.isEmpty else { return }
        if restoreReturnPoint(tab: .playlists, depth: playlistsPath.count) { return }
        playlistsPath.removeLast()
    }

    /// Label for the Back control on a Collection-tab detail page.
    var collectionBackTitle: String {
        if let point = pendingReturnPoint(tab: .collection, depth: collectionPath.count) {
            return Self.backTitle(for: point)
        }
        if collectionPath.count >= 2 {
            return Self.collectionPageTitle(collectionPath[collectionPath.count - 2])
        }
        return "Back to Albums"
    }

    /// Label for the Back control on a Playlists-tab detail page.
    var playlistsBackTitle: String {
        if let point = pendingReturnPoint(tab: .playlists, depth: playlistsPath.count) {
            return Self.backTitle(for: point)
        }
        return "Back to Playlists"
    }

    private static func collectionPageTitle(_ route: String) -> String {
        NavigationRoute.artistKey(from: route) != nil ? "Back to Artist" : "Back to Album"
    }

    private static func backTitle(for point: ReturnPoint) -> String {
        switch point.tab {
        case .collection:
            if let last = point.collectionPath.last { return collectionPageTitle(last) }
            return "Back to Collection"
        case .playlists:
            return point.playlistsPath.isEmpty ? "Back to Playlists" : "Back to Playlist"
        default:
            return "Back to \(point.tab.rawValue)"
        }
    }

    private func pendingReturnPoint(tab: AppTab, depth: Int) -> ReturnPoint? {
        guard let point = returnStack.last,
              point.destinationTab == tab, point.entryDepth == depth else { return nil }
        return point
    }

    private func restoreReturnPoint(tab: AppTab, depth: Int) -> Bool {
        guard let point = returnStack.last,
              point.destinationTab == tab, point.entryDepth == depth else { return false }
        returnStack.removeLast()
        isJumping = true
        collectionPath = point.collectionPath
        playlistsPath = point.playlistsPath
        selectedTab = point.tab
        isJumping = false
        return true
    }
}

/// Encoding helpers for the shared String-typed navigation stack. Album IDs
/// flow through as plain strings; artist pages use the `"artist:"` prefix.
enum NavigationRoute {
    static let artistPrefix = "artist:"

    static func artist(key: String) -> String { "\(artistPrefix)\(key)" }

    static func artistKey(from value: String) -> String? {
        guard value.hasPrefix(artistPrefix) else { return nil }
        return String(value.dropFirst(artistPrefix.count))
    }
}
