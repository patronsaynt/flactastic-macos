import Foundation

/// One planned move from `sourceURL` to `destinationURL`. `unchanged` means the
/// track already lives at its target path. `conflict` means two or more tracks
/// were assigned the same destination — the executor will dedup with `(1)`,
/// `(2)`, etc., but the UI surfaces the conflict so the user can adjust the
/// template if they'd rather avoid the suffix.
struct OrganizerOperation: Identifiable, Hashable {
    enum Status: Hashable {
        case move
        case unchanged
        case conflict(reason: String)
    }

    let id: UUID
    let track: Track
    let sourceURL: URL
    let destinationURL: URL
    let status: Status

    var destinationFolder: URL { destinationURL.deletingLastPathComponent() }
}

enum OrganizerPlanner {
    /// Computes the move plan for `tracks` under `rootURL` using `profile`.
    /// Returns operations in stable, sorted order so the preview UI doesn't
    /// shuffle on small edits.
    static func plan(tracks: [Track], profile: OrganizerProfile, rootURL: URL, resolver: ArtistResolver? = nil) -> [OrganizerOperation] {
        var preliminary: [(track: Track, dest: URL)] = []
        preliminary.reserveCapacity(tracks.count)

        for track in tracks {
            var folder = rootURL
            for level in profile.levels {
                let raw = OrganizerTemplate.render(level.nameTemplate, for: track,
                                                   fallback: level.displayLabel,
                                                   primaryArtistOnly: profile.usePrimaryArtistOnly, resolver: resolver)
                folder.appendPathComponent(raw, isDirectory: true)
            }
            // Preserve the original extension casing. Lowercasing extensions
            // caused a silent no-op on macOS's case-insensitive filesystem:
            // moveItem(Song.FLAC → Song.flac) succeeds but doesn't rename, so
            // the file stays .FLAC, the next scan picks it up again, and it
            // permanently appeared as needing a move.
            let ext = track.url.pathExtension
            let renderedName = OrganizerTemplate.render(profile.fileTemplate, for: track,
                                                        fallback: "Untitled",
                                                        primaryArtistOnly: profile.usePrimaryArtistOnly, resolver: resolver)
            let filename = ext.isEmpty ? renderedName : "\(renderedName).\(ext)"
            let dest = folder.appendingPathComponent(filename).standardizedFileURL
            preliminary.append((track, dest))
        }

        // Detect in-plan collisions: two tracks aimed at the same destination.
        var collisionCount: [URL: Int] = [:]
        for entry in preliminary {
            collisionCount[entry.dest, default: 0] += 1
        }

        var ops: [OrganizerOperation] = []
        ops.reserveCapacity(preliminary.count)
        for (track, dest) in preliminary {
            let source = track.url.standardizedFileURL
            let status: OrganizerOperation.Status
            // Use case-insensitive path comparison: macOS filesystems are
            // case-insensitive, so "Song.FLAC" and "Song.flac" are the same
            // file even though they're unequal as Swift strings.
            let alreadyInPlace = source.path.caseInsensitiveCompare(dest.path) == .orderedSame
            if alreadyInPlace {
                status = .unchanged
            } else if (collisionCount[dest] ?? 0) > 1 {
                status = .conflict(reason: "Multiple tracks resolve to this destination")
            } else {
                status = .move
            }
            ops.append(OrganizerOperation(
                id: track.id,
                track: track,
                sourceURL: source,
                destinationURL: dest,
                status: status
            ))
        }

        return ops.sorted { lhs, rhs in
            lhs.destinationURL.path.localizedStandardCompare(rhs.destinationURL.path) == .orderedAscending
        }
    }
}
