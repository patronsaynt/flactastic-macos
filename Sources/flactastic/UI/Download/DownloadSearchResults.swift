import SwiftUI

/// Where a result's one-click download has got to.
enum QuickDownloadState: Equatable {
    case idle
    /// Lucida is reading the release to list its tracks.
    case resolving
    /// Nil while queued or before the size is known.
    case progress(CGFloat?)
    case done
    case failed(String)
}

/// Search results on the Download tab: the release most likely wanted, the
/// matching songs beside it, then every other album and EP. Clicking a
/// result opens it like a pasted link; its download button queues it
/// straight away. ↑ / ↓ move between results, Return opens, ⌘Return
/// downloads.
struct DownloadSearchResults: View {
    let results: CatalogSearchResults
    let ownership: LibraryOwnership
    let state: (CatalogResult) -> QuickDownloadState
    let onOpen: (CatalogResult) -> Void
    let onDownload: (CatalogResult) -> Void
    var focus: FocusState<String?>.Binding
    /// ↑ from the first result goes back to the field.
    let onLeaveTop: () -> Void

    @State private var showsAllTracks = false
    @State private var showsAllAlbums = false

    private static let trackPreview = 5
    private static let albumPreview = 12

    private var tracks: [CatalogResult] {
        showsAllTracks ? results.tracks : Array(results.tracks.prefix(Self.trackPreview))
    }

    private var albums: [CatalogResult] {
        showsAllAlbums ? results.albums : Array(results.albums.prefix(Self.albumPreview))
    }

    /// Every result in keyboard order.
    private var order: [String] {
        (results.top.map { [$0.id] } ?? []) + tracks.map(\.id) + albums.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            if results.top != nil || !results.tracks.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 36) {
                        topColumn.frame(width: 380)
                        tracksColumn.frame(minWidth: 380)
                    }
                    VStack(alignment: .leading, spacing: 36) {
                        topColumn.frame(maxWidth: 460)
                        tracksColumn
                    }
                }
            }
            if !results.albums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    header("Albums & EPs", total: results.albums.count, preview: Self.albumPreview, expanded: $showsAllAlbums)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18)], alignment: .leading, spacing: 22) {
                        ForEach(albums) { album in
                            SearchAlbumCard(
                                result: album,
                                showsArtist: !sameArtist(album),
                                isOwned: ownership.owns(album),
                                state: state(album),
                                isFocused: focus.wrappedValue == album.id,
                                onOpen: { onOpen(album) },
                                onDownload: { onDownload(album) }
                            )
                            .modifier(keys(album))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var topColumn: some View {
        if let top = results.top {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Top result")
                TopResultCard(
                    result: top,
                    isOwned: ownership.owns(top),
                    state: state(top),
                    isFocused: focus.wrappedValue == top.id,
                    onOpen: { onOpen(top) },
                    onDownload: { onDownload(top) }
                )
                .modifier(keys(top))
            }
        }
    }

    @ViewBuilder
    private var tracksColumn: some View {
        if !results.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                header("Tracks", total: results.tracks.count, preview: Self.trackPreview, expanded: $showsAllTracks)
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        SearchTrackRow(
                            result: track,
                            isOwned: ownership.owns(track),
                            state: state(track),
                            isFocused: focus.wrappedValue == track.id,
                            onOpen: { onOpen(track) },
                            onDownload: { onDownload(track) }
                        )
                        .modifier(keys(track))
                    }
                }
            }
        }
    }

    /// Albums by someone other than the top result's artist name them.
    private func sameArtist(_ result: CatalogResult) -> Bool {
        let main = results.top?.artist ?? results.query
        return ArtistResolver.key(for: result.artist) == ArtistResolver.key(for: main)
    }

    private func header(_ title: String, total: Int, preview: Int, expanded: Binding<Bool>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle(title)
            Spacer()
            if total > preview {
                Button(expanded.wrappedValue ? "Show less" : "Show all \(total)") {
                    withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4)) { expanded.wrappedValue.toggle() }
                }
                .buttonStyle(QuietTextButtonStyle())
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .heavy))
            .tracking(-0.4)
            .foregroundStyle(Theme.textPrimary)
    }

    private func keys(_ result: CatalogResult) -> ResultKeys {
        ResultKeys(id: result.id, order: order, focus: focus, onLeaveTop: onLeaveTop,
                   onOpen: { onOpen(result) }, onDownload: { onDownload(result) })
    }
}

/// Makes a result focusable and moves through the results with the arrow
/// keys; Return opens it and ⌘Return downloads it.
private struct ResultKeys: ViewModifier {
    let id: String
    let order: [String]
    var focus: FocusState<String?>.Binding
    let onLeaveTop: () -> Void
    let onOpen: () -> Void
    let onDownload: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: id)
            .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: .down) { press in
                guard let index = order.firstIndex(of: id) else { return .ignored }
                switch press.key {
                case .upArrow:
                    if index == 0 { onLeaveTop() } else { focus.wrappedValue = order[index - 1] }
                case .downArrow:
                    if index + 1 < order.count { focus.wrappedValue = order[index + 1] }
                default:
                    if press.modifiers.contains(.command) { onDownload() } else { onOpen() }
                }
                return .handled
            }
    }
}

// MARK: - Top result

private struct TopResultCard: View {
    let result: CatalogResult
    let isOwned: Bool
    let state: QuickDownloadState
    let isFocused: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchCover(url: result.coverURL, cornerRadius: 10)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.45), radius: 15, y: 16)
            Text(result.title)
                .font(.system(size: 30, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            Text(meta)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.top, 8)
            HStack(spacing: 8) {
                if isOwned && state == .idle {
                    Label("In your library", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                } else {
                    downloadButton
                }
                Button("Open", action: onOpen)
                    .buttonStyle(SheetPillStyle())
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.textPrimary.opacity(isHovering || isFocused ? 0.09 : 0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.title), \(result.kind.label) by \(result.artist)")
    }

    private var meta: String {
        var parts = [result.kind.label, result.artist]
        if let year = result.year { parts.append(String(year)) }
        if let count = result.trackCount { parts.append("\(count) track\(count == 1 ? "" : "s")") }
        if let seconds = result.durationSeconds, seconds >= 60 { parts.append("\(seconds / 60) min") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch state {
        case .idle, .failed:
            Button(action: onDownload) {
                Label("Download \(result.kind.label.lowercased())", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(SheetPillStyle(isPrimary: true))
            .help(failure ?? "Download every track")
        case .resolving, .progress:
            HStack(spacing: 8) {
                ProgressRing(fraction: { if case .progress(let f) = state { return f }; return nil }())
                    .frame(width: 14, height: 14)
                Text(state == .resolving ? "Getting tracks…" : "Downloading")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
        case .done:
            Label("Downloaded", systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.qualityCD)
                .padding(.horizontal, 6)
        }
        Spacer(minLength: 8)
    }

    private var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}

// MARK: - Track row

private struct SearchTrackRow: View {
    let result: CatalogResult
    let isOwned: Bool
    let state: QuickDownloadState
    let isFocused: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            SearchCover(url: result.thumbnailURL, cornerRadius: 6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if result.isExplicit { ExplicitMark() }
                }
                Text([result.artist, result.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if isOwned {
                Text("In Library")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(result.durationSeconds.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "")
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
            QuickAction(state: state, isOwned: isOwned, isActive: isHovering || isFocused,
                        noun: "track", onDownload: onDownload)
                .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.textPrimary.opacity(isHovering || isFocused ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.title) by \(result.artist)")
    }
}

/// The row's fixed-size button slot: a download arrow on hover, a ring
/// while it's on its way, then a check. Something already in the library
/// shows a quiet check instead, since a download would skip it.
private struct QuickAction: View {
    let state: QuickDownloadState
    let isOwned: Bool
    let isActive: Bool
    let noun: String
    let onDownload: () -> Void

    var body: some View {
        switch state {
        case .resolving:
            ProgressRing(fraction: nil).frame(width: 16, height: 16)
        case .progress(let fraction):
            ProgressRing(fraction: fraction).frame(width: 16, height: 16)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.qualityCD)
                .help("Downloaded")
        case .failed(let message):
            button(icon: "arrow.down.to.line", color: Theme.qualityLow, help: "\(message) Download again.")
        case .idle:
            if isOwned {
                InLibraryCheck()
            } else {
                button(icon: "arrow.down.to.line", color: Theme.textPrimary, help: "Download \(noun)")
                    .opacity(isActive ? 1 : 0)
            }
        }
    }

    private func button(icon: String, color: Color, help: String) -> some View {
        Button(action: onDownload) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Album card

private struct SearchAlbumCard: View {
    let result: CatalogResult
    let showsArtist: Bool
    let isOwned: Bool
    let state: QuickDownloadState
    let isFocused: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void

    @State private var isHovering = false

    private var lifted: Bool { isHovering || isFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SearchCover(url: result.thumbnailURL ?? result.coverURL, cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(SquareSlot())
                .overlay(alignment: .topLeading) {
                    if isOwned {
                        Label("In Library", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .labelStyle(TightLabelStyle())
                            .foregroundStyle(Color.white.opacity(0.95))
                            .padding(.leading, 6).padding(.trailing, 8)
                            .frame(height: 22)
                            .background(Color.black.opacity(0.62), in: Capsule())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) { quickButton.padding(10) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(lifted ? 0.45 : 0.3), radius: lifted ? 16 : 10, y: lifted ? 12 : 8)
                .offset(y: lifted ? -3 : 0)
                .padding(.bottom, 8)
            Text(result.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.3)) { isHovering = hovering }
        }
        .help(showsArtist ? "\(result.title) · \(result.artist)" : result.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.title), \(result.kind.label) by \(result.artist)")
    }

    private var subtitle: String {
        var parts = [result.kind.label]
        if let year = result.year {
            parts.append(String(year))
        } else if let count = result.trackCount {
            parts.append("\(count) track\(count == 1 ? "" : "s")")
        }
        if showsArtist { parts.append(result.artist) }
        return parts.joined(separator: " · ")
    }

    /// A round button on the cover: shown on hover, and kept while the
    /// release downloads so its progress stays visible.
    @ViewBuilder
    private var quickButton: some View {
        let showing = lifted || state != .idle
        ZStack {
            Circle().fill(Theme.accent)
            switch state {
            case .resolving:
                ProgressRing(fraction: nil, tint: Theme.background).frame(width: 16, height: 16)
            case .progress(let fraction):
                ProgressRing(fraction: fraction, tint: Theme.background).frame(width: 16, height: 16)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.background)
            case .idle, .failed:
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(state == .idle ? Theme.background : Theme.qualityLow)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help({ if case .failed(let m) = state { return "\(m) Download again." }; return "Download \(result.kind.label.lowercased())" }())
            }
        }
        .frame(width: 38, height: 38)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 6)
        .opacity(showing ? 1 : 0)
        .offset(y: showing ? 0 : 6)
        .allowsHitTesting(showing)
    }
}

// MARK: - Small parts

/// The mark for a track already in the library, in a track row's action slot.
struct InLibraryCheck: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 30, height: 30)
            .help("In your library")
            .accessibilityLabel("In your library")
    }
}

/// Cover art from a URL, with the app's dark placeholder until it loads.
private struct SearchCover: View {
    let url: URL?
    let cornerRadius: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ExplicitMark: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 14, height: 14)
            .background(Theme.textPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Explicit")
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
