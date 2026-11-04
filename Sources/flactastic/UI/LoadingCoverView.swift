import SwiftUI

/// Full-bleed cover shown over the main UI while the initial library scan
/// and metadata load are in flight. Keeps album/track grids from visibly
/// reshuffling as tags stream in. The mark animates as UI for nerds picks.
struct LoadingCoverView: View {
    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            BrandLoader(height: 48, bloom: true)
        }
    }
}
