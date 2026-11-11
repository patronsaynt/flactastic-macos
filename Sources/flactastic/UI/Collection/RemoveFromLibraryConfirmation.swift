import SwiftUI

/// A pending "remove from library" request, shared by the track and album
/// context menus.
struct LibraryRemovalRequest: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [Track]
}

extension View {
    /// Presents a confirmation before deleting the request's files from the
    /// library, then performs the removal.
    func removeFromLibraryConfirmation(_ request: Binding<LibraryRemovalRequest?>,
                                       library: LibraryStore) -> some View {
        confirmationDialog(
            request.wrappedValue.map { "Remove \"\($0.title)\" from Library?" } ?? "",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: request.wrappedValue
        ) { pending in
            Button("Delete from Library", role: .destructive) {
                library.removeTracks(pending.tracks)
                request.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { request.wrappedValue = nil }
        } message: { pending in
            let n = pending.tracks.count
            if ServerSession.current?.isActive == true {
                Text(n == 1
                     ? "The file will be deleted from the server. It stays in the server's trash for 30 days."
                     : "\(n) files will be deleted from the server. They stay in the server's trash for 30 days.")
            } else {
                Text(n == 1
                     ? "The file will be deleted from your library and moved to the Trash."
                     : "\(n) files will be deleted from your library and moved to the Trash.")
            }
        }
    }
}
