import SwiftUI

/// Shown when a library genre scan finishes: how many albums were scanned,
/// how many got genres (and how many tracks were written), then each album
/// neither service knew, by name. Clicking one opens it, to tag by hand.
struct GenreScanSummarySheet: View {
    let summary: GenreScanner.ScanSummary

    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationRouter.self) private var router

    var body: some View {
        FLSheet(title: summary.stopped ? "Genre Scan Stopped" : "Genre Scan Complete",
                width: 480, height: height, contentScrolls: true) {
            VStack(alignment: .leading, spacing: 28) {
                figures
                if !summary.missed.isEmpty {
                    missedList
                } else {
                    Text(closingLine)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
        } footer: {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Tall enough for the list (up to eight rows show before it scrolls).
    private var height: CGFloat {
        guard !summary.missed.isEmpty else { return 300 }
        return 360 + CGFloat(min(summary.missed.count, 8)) * 46
    }

    // MARK: Figures

    private var figures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 36) {
            figure(summary.scanned, "Scanned", unit: summary.scanned == 1 ? "album" : "albums")
            figure(summary.found, "Found", unit: summary.found == 1 ? "album" : "albums")
            figure(summary.tracksWritten, "Tagged", unit: summary.tracksWritten == 1 ? "track" : "tracks")
        }
    }

    private func figure(_ value: Int, _ label: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SheetLabel(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.formatted())
                    .font(.system(size: 30, weight: .heavy).monospacedDigit())
                    .tracking(-0.8)
                    .foregroundStyle(Theme.textPrimary)
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Missed

    private var missedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetLabel(text: "No genre found · \(summary.missed.count)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(summary.missed) { album in
                        MissedRow(album: album) {
                            dismiss()
                            router.showSettings = false
                            router.navigateToAlbum(id: album.id)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Rows keep their own hover inset; their text lines up with the labels.
            .padding(.horizontal, -10)
            .frame(maxHeight: .infinity)
            Text(closingLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var closingLine: String {
        var parts: [String] = []
        if summary.missed.isEmpty, summary.unreachable == 0 {
            parts.append(summary.scanned == 0 ? "Nothing needed a genre." : "Every album scanned has a genre now.")
        } else if !summary.missed.isEmpty {
            parts.append("Neither Deezer nor MusicBrainz knows these. Click one to open it and add a genre yourself.")
        }
        if summary.unreachable > 0 {
            let n = summary.unreachable
            parts.append("\(n) \(n == 1 ? "album" : "albums") couldn't be checked, and will be tried again next scan.")
        }
        if summary.stopped { parts.append("Scan again to pick up where this left off.") }
        return parts.joined(separator: " ")
    }
}

/// One album the scan couldn't find: title over artist, opening on click.
private struct MissedRow: View {
    let album: GenreScanner.ScanSummary.Missed
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let artist = album.artist {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.textPrimary.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Open \(album.title)")
        .accessibilityLabel("\(album.title)\(album.artist.map { ", \($0)" } ?? ""). Open album")
    }
}
