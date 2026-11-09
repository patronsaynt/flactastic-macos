import Foundation

/// Packs/unpacks a primary genre plus up to `maxSecondaryCount` secondary
/// genres into the single GENRE tag string read/written via TagLib's basic Tag
/// API (`taglib_tag_genre` / `taglib_tag_set_genre`). There is no multi-value
/// GENRE tag on disk — this mirrors how `ArtistResolver` packs multiple artists
/// into one ARTIST tag string, but is kept as its own small resolver since
/// genre has none of ArtistResolver's canonical-name or fuzzy-splitting logic.
///
/// Storage form: `"Primary ; Secondary One ; Secondary Two"` — primary always
/// first, joined with `" ; "` (space-semicolon-space), matching
/// `ArtistResolver.joinExplicit`'s delimiter so GENRE tags stay readable in
/// third-party tag editors. A legacy single-genre tag (no delimiter) round-trips
/// unchanged as a primary genre with no secondaries.
enum GenreResolver {
    /// Maximum number of secondary genres stored alongside the primary.
    static let maxSecondaryCount = 3

    /// Builds the canonical on-disk GENRE string from a primary genre and up to
    /// `maxSecondaryCount` secondary genres.
    ///
    /// - Trims whitespace on every entry and drops empties.
    /// - Drops any secondary genre that case-insensitively matches the primary.
    /// - Deduplicates secondary genres against each other (case-insensitive,
    ///   first occurrence wins).
    /// - Caps the result at `maxSecondaryCount` secondary entries; extras are
    ///   silently dropped.
    /// - Returns `nil` when nothing survives, so callers can treat that as
    ///   "clear the tag".
    static func join(primary: String?, secondary: [String]) -> String? {
        let trimmedPrimary = primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrimary = (trimmedPrimary?.isEmpty ?? true) ? nil : trimmedPrimary

        var seen = Set<String>()
        if let cleanPrimary { seen.insert(cleanPrimary.lowercased()) }

        var cleanSecondary: [String] = []
        for raw in secondary {
            guard cleanSecondary.count < maxSecondaryCount else { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            cleanSecondary.append(trimmed)
        }

        let all = ([cleanPrimary].compactMap { $0 }) + cleanSecondary
        guard !all.isEmpty else { return nil }
        return all.joined(separator: " ; ")
    }

    /// Splits a raw GENRE tag string into `(primary, secondary)`.
    ///
    /// - No explicit delimiter present → the whole trimmed string is the primary
    ///   genre and `secondary` is empty. This makes legacy single-genre files
    ///   round-trip unchanged.
    /// - Delimiter present → first piece is the primary; up to
    ///   `maxSecondaryCount` of the remaining pieces (deduplicated against the
    ///   primary and each other, case-insensitively) become secondaries.
    /// - Empty/nil input → `(nil, [])`.
    static func split(_ raw: String?) -> (primary: String?, secondary: [String]) {
        guard let raw else { return (nil, []) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, []) }

        guard let pieces = explicitlySeparated(trimmed) else {
            return (trimmed, [])
        }
        guard let first = pieces.first else { return (nil, []) }

        var seen = Set<String>([first.lowercased()])
        var secondary: [String] = []
        for piece in pieces.dropFirst() {
            guard secondary.count < maxSecondaryCount else { break }
            guard seen.insert(piece.lowercased()).inserted else { continue }
            secondary.append(piece)
        }
        return (first, secondary)
    }

    /// If `raw` uses one of the explicit multi-genre delimiters, returns the
    /// trimmed, non-empty pieces. Otherwise nil. Genres only ever split on
    /// these safe separators, never on "&", "," or "/" ("Drum & Bass").
    private static func explicitlySeparated(_ raw: String) -> [String]? {
        MultiValueParser.splitSafe(raw)
    }
}
