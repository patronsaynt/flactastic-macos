import SwiftUI

/// The confirmation the user asked for: exactly what a sync is about to do,
/// and in particular what it will **overwrite**, before a single byte moves.
///
/// There is no silent merge anywhere in this feature. When two devices disagree
/// about a track's tags or a playlist's contents, the incoming copy wins — and
/// this sheet is where the user is told that and can say no. The overwrite list
/// comes first and is expanded by default; the additions are the reassuring
/// part and can wait below.
struct SyncPlanSheet: View {
    let plan: SyncPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var showAdditions = false

    private var isPush: Bool { plan.direction == .push }
    private var target: String { isPush ? "the other device" : "this Mac" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header

            if plan.overwriteCount > 0 {
                overwriteSection
            }
            if !plan.newTracks.isEmpty || !plan.newPlaylists.isEmpty {
                additionsSection
            }

            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560)
        .frame(maxHeight: 620)
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(plan.overwriteCount > 0 ? "Review before syncing" : "Ready to sync")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Text(summary)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !plan.newTracks.isEmpty {
            parts.append("\(plan.newTracks.count) new track\(plan.newTracks.count == 1 ? "" : "s")")
        }
        if !plan.newPlaylists.isEmpty {
            parts.append("\(plan.newPlaylists.count) new playlist\(plan.newPlaylists.count == 1 ? "" : "s")")
        }
        let size = ByteCountFormatter.string(fromByteCount: plan.totalTransferBytes, countStyle: .file)

        if parts.isEmpty && plan.overwriteCount == 0 {
            return "Both devices already match. Nothing will change."
        }
        var text = parts.isEmpty
            ? "Nothing new will be added to \(target)."
            : "\(parts.joined(separator: " and ")) will be copied to \(target) (\(size))."
        if plan.overwriteCount > 0 {
            text += " \(plan.overwriteCount) existing item\(plan.overwriteCount == 1 ? "" : "s") "
                  + "on \(target) will be replaced."
        }
        return text
    }

    // MARK: - Overwrites

    private var overwriteSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Will be replaced", systemImage: "exclamationmark.triangle")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)

            Text("These already exist on \(target) with different contents. "
               + "The version from \(isPush ? "this Mac" : "the other device") will replace them.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.trackConflicts) { conflict in
                        row(
                            title: conflict.incoming.title,
                            detail: [conflict.incoming.artist, conflict.incoming.album]
                                .compactMap { $0 }.joined(separator: " — "),
                            note: conflict.differingFields.joined(separator: ", ")
                        )
                    }
                    ForEach(plan.playlistConflicts) { conflict in
                        row(
                            title: conflict.incoming.name,
                            detail: "Playlist · \(conflict.incoming.entryCount) tracks",
                            note: "Contents differ"
                        )
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    // MARK: - Additions

    private var additionsSection: some View {
        DisclosureGroup(isExpanded: $showAdditions) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.newPlaylists) { playlist in
                        row(title: playlist.name,
                            detail: "Playlist · \(playlist.entryCount) tracks",
                            note: nil)
                    }
                    ForEach(plan.newTracks) { track in
                        row(title: track.title,
                            detail: [track.artist, track.album].compactMap { $0 }.joined(separator: " — "),
                            note: ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
                    }
                }
            }
            .frame(maxHeight: 200)
        } label: {
            Text("New items (\(plan.newTracks.count + plan.newPlaylists.count))")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Rows

    private func row(title: String, detail: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let note, !note.isEmpty {
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(plan.overwriteCount > 0 ? "Replace and Sync" : "Sync", action: onConfirm)
                .keyboardShortcut(.defaultAction)
        }
    }
}
