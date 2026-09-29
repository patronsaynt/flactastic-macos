import SwiftUI

/// The confirmation the user asked for: exactly what a sync is about to do,
/// and in particular what it will **overwrite**, before a single byte moves —
/// and the place to choose which of it to do.
///
/// There is no silent merge anywhere in this feature. When two devices disagree
/// about a track's tags or a playlist's contents, the incoming copy wins — and
/// this sheet is where the user is told that and can say no, per item.
///
/// Everything starts ticked, so a user who just wants the whole library presses
/// Sync and is done. Unticking narrows the run by artist, album, track, or
/// playlist; the checklist logic is `SyncPickList`, shared with iOS.
struct SyncPlanSheet: View {
    let plan: SyncPlan
    let onConfirm: (SyncSelection) -> Void
    let onCancel: () -> Void

    @State private var picks: SyncPickList
    @State private var expandedArtists: Set<String> = []
    @State private var expandedAlbums: Set<String> = []

    init(plan: SyncPlan, onConfirm: @escaping (SyncSelection) -> Void, onCancel: @escaping () -> Void) {
        self.plan = plan
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _picks = State(initialValue: SyncPickList(plan: plan))
    }

    private var isPush: Bool { plan.direction == .push }
    private var target: String { isPush ? "the other device" : "this Mac" }
    private var source: String { isPush ? "this Mac" : "the other device" }

    var body: some View {
        FLSheet(
            title: plan.overwriteCount > 0 ? "Review before syncing" : "Choose what to sync",
            width: 600, height: 660
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    Text(summary)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    entireLibrary

                    if plan.overwriteCount > 0 {
                        Text("Items marked “Replaces” already exist on \(target) with different "
                           + "contents. The version from \(source) will replace them.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !picks.artists.isEmpty { tracksSection }
                    if !picks.playlists.isEmpty { playlistsSection }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            footer
        }
    }

    // MARK: - Summary

    private var summary: String {
        if plan.isEmpty { return "Both devices already match. Nothing will change." }
        if picks.isEmptySelection { return "Nothing is selected. Tick what you want copied to \(target)." }

        var parts: [String] = []
        let tracks = picks.selectedTrackCount
        let playlists = picks.selectedPlaylistCount
        if tracks > 0 { parts.append("\(tracks) track\(tracks == 1 ? "" : "s")") }
        if playlists > 0 { parts.append("\(playlists) playlist\(playlists == 1 ? "" : "s")") }
        var text = "\(parts.joined(separator: " and ")) will be copied to \(target)"
        if picks.selectedBytes > 0 {
            text += " (\(ByteCountFormatter.string(fromByteCount: picks.selectedBytes, countStyle: .file)))"
        }
        return text + "."
    }

    // MARK: - Entire library

    private var entireLibrary: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Entire library")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("Everything on \(source) that \(target) is missing or has differently.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle("Entire library", isOn: Binding(
                get: { picks.isEverything },
                set: { picks.setEverything($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            FLEyebrow(text: "Artists, albums and tracks")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(picks.artists) { artist in
                    artistRow(artist)
                    if expandedArtists.contains(artist.id) {
                        ForEach(artist.albums) { album in
                            albumRow(album)
                            if expandedAlbums.contains(album.id) {
                                ForEach(album.tracks) { track in trackRow(track) }
                            }
                        }
                    }
                }
            }
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func artistRow(_ artist: SyncPickList.Artist) -> some View {
        row(
            indent: 0,
            mark: picks.mark(artist.trackIDs),
            title: artist.name,
            detail: countDetail(artist.trackIDs, bytes: artist.bytes),
            note: nil,
            expanded: expandedArtists.contains(artist.id),
            onToggle: { picks.toggle(artist.trackIDs) },
            onExpand: { toggle(&expandedArtists, artist.id) }
        )
    }

    private func albumRow(_ album: SyncPickList.Album) -> some View {
        row(
            indent: 1,
            mark: picks.mark(album.trackIDs),
            title: album.title,
            detail: countDetail(album.trackIDs, bytes: album.bytes),
            note: nil,
            expanded: expandedAlbums.contains(album.id),
            onToggle: { picks.toggle(album.trackIDs) },
            onExpand: { toggle(&expandedAlbums, album.id) }
        )
    }

    private func trackRow(_ track: SyncPickList.Track) -> some View {
        row(
            indent: 2,
            mark: picks.mark([track.id]),
            title: track.entry.title,
            detail: [track.creditedArtist,
                     ByteCountFormatter.string(fromByteCount: track.entry.fileSize, countStyle: .file)]
                .compactMap { $0 }.joined(separator: " · "),
            note: track.replaces.map { "Replaces · \($0)" },
            expanded: nil,
            onToggle: { picks.toggle([track.id]) },
            onExpand: nil
        )
    }

    private func countDetail(_ ids: [UUID], bytes: Int64) -> String {
        let included = picks.includedCount(of: ids)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let tracks = "\(ids.count) track\(ids.count == 1 ? "" : "s")"
        return included == ids.count ? "\(tracks) · \(size)" : "\(included) of \(tracks)"
    }

    // MARK: - Playlists

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            FLEyebrow(text: "Playlists")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(picks.playlists) { playlist in
                    row(
                        indent: 0,
                        mark: picks.isIncluded(playlist: playlist.id) ? .all : .none,
                        title: playlist.entry.name,
                        detail: "\(playlist.entry.entryCount) tracks",
                        note: playlist.replacesExisting ? "Replaces · contents differ" : nil,
                        expanded: nil,
                        onToggle: { picks.togglePlaylist(playlist.id) },
                        onExpand: nil
                    )
                }
            }
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))

            Text("A playlist brings its list of tracks, not the tracks themselves — "
               + "untick an album and its songs show as missing in any playlist that uses them.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rows

    private func row(
        indent: Int,
        mark: SyncPickList.Mark,
        title: String,
        detail: String,
        note: String?,
        expanded: Bool?,
        onToggle: @escaping () -> Void,
        onExpand: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            // Chevron column is reserved on every row so checkboxes line up.
            Group {
                if let expanded, let onExpand {
                    Button(action: onExpand) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse \(title)" : "Expand \(title)")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }

            Button(action: onToggle) {
                HStack(spacing: Theme.Spacing.sm) {
                    checkbox(mark)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(Theme.Font.body)
                            .foregroundStyle(mark == .none ? Theme.textTertiary : Theme.textPrimary)
                            .lineLimit(1)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    if let note {
                        Text(note)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(mark == .all ? "Selected" : mark == .some ? "Partly selected" : "Not selected")
        }
        .padding(.leading, Theme.Spacing.md + CGFloat(indent) * 22)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func checkbox(_ mark: SyncPickList.Mark) -> some View {
        Image(systemName: mark == .all ? "checkmark.square.fill"
                        : mark == .some ? "minus.square.fill" : "square")
            .font(.system(size: 14))
            .foregroundStyle(mark == .none ? Theme.textTertiary : Theme.textPrimary)
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    // MARK: - Footer

    private var confirmTitle: String {
        if picks.isEverything {
            return plan.overwriteCount > 0 ? "Replace and Sync" : "Sync"
        }
        let count = picks.selectedTrackCount
        return count > 0 ? "Sync \(count) Track\(count == 1 ? "" : "s")" : "Sync Playlists"
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) { onConfirm(picks.selection) }
                .buttonStyle(PillButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(picks.isEmptySelection && !plan.isEmpty)
        }
    }
}
