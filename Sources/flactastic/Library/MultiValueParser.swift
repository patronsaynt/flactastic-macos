import Foundation
import os

/// The one place multi-value tag strings (artist, album artist, genre) are
/// split. Pure: no I/O, no library state beyond what callers pass in, so it
/// can be tested from `Tests/Fixtures/metadata-parsing.json` and ported.
///
/// Source priority for one field (first match wins):
/// 1. The plural tag (ARTISTS, ALBUMARTISTS), taken as is.
/// 2. Native multi-values (repeated Vorbis/APE fields, null-separated
///    ID3v2.4, repeated MP4 data atoms), taken as is.
/// 3. One string split on a safe separator (NUL, ";", " / ", backslash).
/// 4. One string with an ambiguous separator ("&", ",", "/", " x ",
///    "feat." …): split only when every part is already a standalone value in
///    the library, or when the MusicBrainz artist ID count matches the parts.
///    Otherwise the string is kept whole and queued for review.
///
/// Tag text is untrusted: values are capped at `maxValueLength` characters and
/// `maxValues` entries per field.
enum MultiValueParser {
    static let maxValueLength = 1024
    static let maxValues = 50

    private static let log = Logger(subsystem: "flactastic", category: "MultiValueParser")

    enum Field: String, Sendable {
        case artist, albumArtist, genre
        /// Genres never use the ambiguous rule: "Drum & Bass" and "R&B/Soul"
        /// are single genres far more often than not.
        var usesAmbiguousRule: Bool { self != .genre }
    }

    /// A saved answer for a raw string from the review queue.
    enum Decision: Codable, Equatable, Sendable {
        case split([String])
        case keep
    }

    enum Outcome: Equatable, Sendable {
        /// The field's values. One element means a single value.
        case values([String])
        /// Kept whole for now; the raw string goes to the review queue.
        case review(String)
    }

    // MARK: - Separators

    /// Safe separators, in priority order: a string is split on the first one
    /// it contains. NUL and ";" are what FLACtastic itself writes; spaced
    /// " / " is iTunes' and TagLib's join for native multi-values (unspaced
    /// "/" stays ambiguous so "AC/DC" survives); a backslash run is Mp3tag's.
    private static let safeSeparators = ["\u{0000}", ";", " / "]

    /// Ambiguous separators. Order matters: longer alternatives first so
    /// "feat." isn't half-matched by "feat". The spaced forms are the ones the
    /// app has always recognised; the bare "&", "," and "/" catch tags written
    /// without spaces.
    private static let ambiguousSeparators: [String] = [
        " featuring ", " feat. ", " feat ", " ft. ", " ft ",
        " vs. ", " vs ",
        " with ",
        " & ", " x ", " X ",
        ", ",
        "&", ",", "/",
    ]

    /// Splits `raw` on its highest-priority safe separator. Nil when it has
    /// none. Pieces are trimmed and empties dropped (not deduped, matching
    /// how the app has always read its own lists).
    static func splitSafe(_ raw: String) -> [String]? {
        for delimiter in safeSeparators where raw.contains(delimiter) {
            return trimmedPieces(raw.components(separatedBy: delimiter))
        }
        if raw.contains("\\") {
            return trimmedPieces(raw.split(separator: "\\", omittingEmptySubsequences: true).map(String.init))
        }
        return nil
    }

    /// True when `raw` contains any ambiguous separator.
    static func hasAmbiguousSeparator(_ raw: String) -> Bool {
        let padded = " \(raw) "
        for token in ambiguousSeparators where padded.range(of: token, options: .caseInsensitive) != nil {
            return true
        }
        return false
    }

    /// Splits on every ambiguous separator, unconditionally. Callers decide
    /// whether to accept the result.
    static func splitAmbiguous(_ raw: String) -> [String] {
        var fragments = [raw]
        for token in ambiguousSeparators {
            fragments = fragments.flatMap { caseInsensitiveSplit($0, separator: token) }
        }
        return trimmedPieces(fragments)
    }

    /// Every separator at once, no checks: for fuzzy matching only (e.g. "is
    /// this remote track already in the library?"), never for display.
    static func splitPermissive(_ raw: String) -> [String] {
        (splitSafe(raw) ?? [raw]).flatMap(splitAmbiguous)
    }

    /// Splits a MusicBrainz ID list. MBIDs are UUIDs, so any separator or
    /// whitespace is safe here.
    static func splitIdentifiers(_ values: [String]) -> [String] {
        values.flatMap {
            $0.components(separatedBy: CharacterSet(charactersIn: "\u{0000};,/\\").union(.whitespacesAndNewlines))
        }.filter { !$0.isEmpty }
    }

    // MARK: - Normalising

    /// Trims, drops empties, dedupes case-insensitively (first casing wins),
    /// and applies the length and count caps.
    static func normalize(_ values: [String], field: Field = .artist) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            if v.count > maxValueLength {
                log.notice("Truncated a \(field.rawValue, privacy: .public) value of \(v.count) characters")
                v = String(v.prefix(maxValueLength))
            }
            guard seen.insert(v.lowercased()).inserted else { continue }
            if out.count == maxValues {
                log.notice("Dropped \(field.rawValue, privacy: .public) values past \(maxValues)")
                break
            }
            out.append(v)
        }
        return out
    }

    // MARK: - Resolving one field

    /// Applies the source priority to one field.
    ///
    /// - Parameters:
    ///   - plural: values of the plural tag (ARTISTS / ALBUMARTISTS); empty if absent.
    ///   - native: values of the singular tag as the container stores them.
    ///   - mbidCount: how many MusicBrainz IDs the file carries for this field.
    ///   - isKnown: whether a value already exists on its own in the library.
    ///     Pass `{ _ in false }` when the library isn't known yet (a single
    ///     file scan); the string then comes back as `.review`.
    ///   - decision: a saved review answer for the raw string, if any.
    static func resolve(
        field: Field,
        plural: [String] = [],
        native: [String],
        mbidCount: Int = 0,
        isKnown: (String) -> Bool = { _ in false },
        decision: Decision? = nil
    ) -> Outcome {
        let fromPlural = normalize(plural, field: field)
        if !fromPlural.isEmpty { return .values(fromPlural) }

        let fromNative = normalize(native, field: field)
        if fromNative.count > 1 { return .values(fromNative) }
        guard let raw = fromNative.first else { return .values([]) }

        if let safe = splitSafe(raw) { return .values(normalize(safe, field: field)) }
        guard field.usesAmbiguousRule, hasAmbiguousSeparator(raw) else { return .values([raw]) }

        switch decision {
        case .split(let parts): return .values(normalize(parts, field: field))
        case .keep: return .values([raw])
        case nil: break
        }
        let parts = normalize(splitAmbiguous(raw), field: field)
        guard parts.count > 1 else { return .values([raw]) }
        if parts.allSatisfy(isKnown) || (mbidCount > 1 && mbidCount == parts.count) {
            return .values(parts)
        }
        return .review(raw)
    }

    // MARK: - Stored form

    /// How a credit field (artist / album artist) is held in `Track`: the
    /// string every surface reads, plus whether it came from a real list.
    ///
    /// A single string is kept exactly as tagged, so files in FLACtastic's
    /// own format ("A ; B", "A; B") read byte for byte as they always have.
    /// A list is stored as its singular tag when that tag is the same list
    /// written out (FLACtastic writes both), else joined with `" ; "`.
    static func storedCredit(plural: [String], native: [String], mbidCount: Int = 0) -> (value: String?, isList: Bool) {
        let list = normalize(plural)
        let singles = native.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !list.isEmpty {
            if singles.count == 1 {
                let single = capped(singles[0])
                let parsed = normalize(splitSafe(single) ?? [single])
                if parsed.map({ $0.lowercased() }) == list.map({ $0.lowercased() }) { return (single, true) }
            }
            return (list.count == 1 ? list[0] : joinList(list), true)
        }
        let nativeList = normalize(native)
        if nativeList.count > 1 { return (joinList(nativeList), true) }
        guard let raw = singles.first.map(capped) else { return (nil, false) }
        if mbidCount > 1, splitSafe(raw) == nil, hasAmbiguousSeparator(raw) {
            let parts = normalize(splitAmbiguous(raw))
            if parts.count == mbidCount { return (joinList(parts), true) }
        }
        return (raw, false)
    }

    /// The genre field as `Track` holds it: primary plus up to
    /// `GenreResolver.maxSecondaryCount` secondaries.
    static func storedGenres(native: [String]) -> (primary: String?, secondary: [String]) {
        let list = normalize(native, field: .genre)
        if list.count > 1 { return GenreResolver.split(joinList(list)) }
        let single = native.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return GenreResolver.split(single.map(capped))
    }

    /// The list form FLACtastic stores and writes: `" ; "` between values.
    static func joinList(_ values: [String]) -> String {
        values.joined(separator: " ; ")
    }

    /// The values a stored credit or genre string stands for.
    static func values(ofStored raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return normalize(splitSafe(raw) ?? [raw])
    }

    private static func capped(_ value: String) -> String {
        guard value.count > maxValueLength else { return value }
        log.notice("Truncated a tag value of \(value.count) characters")
        return String(value.prefix(maxValueLength))
    }

    // MARK: - Helpers

    private static func trimmedPieces(_ pieces: [String]) -> [String] {
        pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func caseInsensitiveSplit(_ s: String, separator: String) -> [String] {
        var pieces: [String] = []
        var remainder = Substring(s)
        while let range = remainder.range(of: separator, options: .caseInsensitive) {
            pieces.append(String(remainder[..<range.lowerBound]))
            remainder = remainder[range.upperBound...]
        }
        pieces.append(String(remainder))
        return pieces
    }
}
