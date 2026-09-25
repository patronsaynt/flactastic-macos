import SwiftUI

/// Top-level Artists grid for the Collection tab. Each cell links into
/// ArtistDetailView via the shared String-typed navigation stack.
struct ArtistsCollectionView: View {
    let searchText: String

    @Environment(LibraryStore.self)        private var library
    @Environment(ArtistStore.self)         private var artistStore
    @Environment(ArtistRemoteCache.self)   private var artistRemoteCache
    @Environment(ArtistImageFetcher.self)  private var artistImageFetcher
    @Environment(Settings.self)            private var settings
    @Environment(NavigationRouter.self)    private var router

    /// Gates the initial bulk reveal — see `CollectionView.canAnimateEntrances`.
    @State private var canAnimateEntrances = false
    private var animatedArtistIDs: Binding<Set<String>> {
        Binding(get: { library.revealedArtistIDs }, set: { library.revealedArtistIDs = $0 })
    }

    /// Cached full artist index. Building it walks every album and track, so
    /// it must NOT live in a computed property read from `body` — entrance
    /// animations and remote image fetches mutate observable state on every
    /// scroll frame, and each mutation would rebuild the whole index. Instead
    /// it's recomputed only when the library or artist overrides change.
    @State private var allSummaries: [ArtistSummary] = []

    private var summaries: [ArtistSummary] {
        guard !searchText.isEmpty else { return allSummaries }
        let q = searchText.lowercased()
        return allSummaries.filter { $0.displayName.lowercased().contains(q) }
    }

    private func rebuildSummaries() {
        let resolver = library.makeArtistResolver()
        allSummaries = library.allArtists(resolver: resolver, overrides: artistStore.overrides)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)],
                spacing: 24
            ) {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                    ArtistGridCell(
                        summary: summary,
                        preferredImage: preferredImage(for: summary)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        router.collectionPath.append(NavigationRoute.artist(key: summary.id))
                    }
                    .riseFadeIn(index: index, animated: summary.id, animatedIDs: animatedArtistIDs, enabled: canAnimateEntrances)
                    .task(id: summary.id) {
                        if settings.autoFetchArtistImages {
                            artistImageFetcher.ensureImage(
                                forKey: summary.id,
                                displayName: summary.displayName
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, collectionGutter)
            .padding(.top, cardHoverHeadroom)
            .padding(.bottom, 100)
        }
        .task {
            rebuildSummaries()
            canAnimateEntrances = true
        }
        .onChange(of: library.tracksRevision) { rebuildSummaries() }
        .onChange(of: artistStore.overrides) { rebuildSummaries() }
    }

    private func preferredImage(for summary: ArtistSummary) -> Data? {
        if let override = artistStore.override(forKey: summary.id),
           let data = override.profileImage ?? override.bannerImage {
            return data
        }
        return artistRemoteCache.entry(forKey: summary.id)?.profileImage
    }
}
