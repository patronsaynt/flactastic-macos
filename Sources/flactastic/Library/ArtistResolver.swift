import Foundation

/// Identifies and parses artist credit strings against the artists known to
/// the library. Splitting rules live in `MultiValueParser`; this adds the
/// library context the parser's ambiguous rule needs: which names exist on
/// their own, saved review decisions, and which strings came from a real list.
struct ArtistResolver: Sendable {
    /// Maps normalised key → preferred display casing observed in tags.
    let canonicalByKey: [String: String]
    /// Keys of names that exist as a value on their own somewhere in the
    /// library: a single-name credit, or one entry of an explicit list. Only
    /// these can confirm an ambiguous split ("A & B" splits when both A and B
    /// are known); fragments of other ambiguous strings never count.
    let standaloneKeys: Set<String>
    /// Saved review answers, keyed by the raw credit string.
    let decisions: [String: MultiValueParser.Decision]
    /// Raw strings that came from a plural tag or native multi-values and so
    /// are never split heuristically.
    let exactRaws: Set<String>

    /// Build a resolver from a track collection.
    ///
    /// **Pass 1** – credits with no separator of any kind, and each entry of
    /// an explicit list (";", NUL, " / ", backslash, a plural tag or a saved
    /// split), are standalone names; first casing wins.
    ///
    /// **Pass 2** – ambiguous credits ("A & B", "A, B") are resolved against
    /// pass 1. A split's parts are already known; an unsplit credit is a name
    /// in its own right ("Earth, Wind & Fire"), so its casing is stored too.
    init(tracks: [Track], decisions: [String: MultiValueParser.Decision] = [:]) {
        var byKey: [String: String] = [:]
        var standalone = Set<String>()
        var ambiguous: [String] = []
        var exact = Set<String>()

        func addStandalone(_ name: String) {
            let key = Self.key(for: name)
            standalone.insert(key)
            if byKey[key] == nil { byKey[key] = name }
        }

        for track in tracks {
            for (raw, isList) in [(track.albumArtist, track.albumArtistIsList), (track.artist, track.artistIsList)] {
                guard let raw, !raw.isEmpty else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if isList { exact.insert(trimmed) }
                if let pieces = MultiValueParser.splitSafe(trimmed) {
                    pieces.forEach(addStandalone)
                } else if case .split(let parts)? = decisions[trimmed] {
                    parts.forEach(addStandalone)
                } else if isList || decisions[trimmed] == .keep || !MultiValueParser.hasAmbiguousSeparator(trimmed) {
                    addStandalone(trimmed)
                } else {
                    ambiguous.append(trimmed)
                }
            }
        }

        // Pass 2 – an unsplit ambiguous credit keeps its own display name.
        for raw in Set(ambiguous) {
            let parts = MultiValueParser.splitAmbiguous(raw)
            let splits = parts.count > 1 && parts.allSatisfy { standalone.contains(Self.key(for: $0)) }
            if !splits {
                let key = Self.key(for: raw)
                if byKey[key] == nil { byKey[key] = raw }
            }
        }

        self.canonicalByKey = byKey
        self.standaloneKeys = standalone
        self.decisions = decisions
        self.exactRaws = exact
    }

    /// Stable lookup key: lowercased, diacritic-folded, whitespace-collapsed.
    static func key(for raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Display name for a key — uses the casing harvested from tags when
    /// available (pass 1 or pass 2 of init), otherwise echoes the key as-is.
    /// The user-facing override in ArtistStore takes precedence over this
    /// value and is applied at the allArtists() call site.
    func displayName(forKey key: String) -> String {
        canonicalByKey[key] ?? key
    }

    /// Parse a raw credit string into one or more artist names, following
    /// `MultiValueParser.resolve`: explicit lists always split; strings from a
    /// plural tag or native values never split further; saved review
    /// decisions apply next; and an ambiguous credit splits only when every
    /// fragment is a standalone name in the library.
    func split(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let explicit = Self.explicitlySeparated(trimmed) { return explicit }
        if exactRaws.contains(trimmed) || standaloneKeys.contains(Self.key(for: trimmed)) { return [trimmed] }
        let outcome = MultiValueParser.resolve(
            field: .artist, native: [trimmed],
            isKnown: { standaloneKeys.contains(Self.key(for: $0)) },
            decision: decisions[trimmed]
        )
        if case .values(let parts) = outcome, !parts.isEmpty { return parts }
        return [trimmed]
    }

    /// True when `raw` is an ambiguous credit this resolver keeps whole only
    /// because nothing confirms a split yet, i.e. it needs a review decision.
    func needsReview(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.explicitlySeparated(trimmed) == nil,
              !exactRaws.contains(trimmed), decisions[trimmed] == nil,
              !standaloneKeys.contains(Self.key(for: trimmed)) else { return false }
        if case .review = MultiValueParser.resolve(
            field: .artist, native: [trimmed], isKnown: { standaloneKeys.contains(Self.key(for: $0)) }
        ) { return true }
        return false
    }

    /// If the string uses one of the explicit multi-artist delimiters, return
    /// the trimmed pieces. Otherwise nil. See `MultiValueParser.splitSafe`.
    static func explicitlySeparated(_ raw: String) -> [String]? {
        MultiValueParser.splitSafe(raw)
    }

    /// The lead credit of a multi-artist string, using only the explicit
    /// storage delimiters — `"Deadmau5 ; Rob Swire"` → `"Deadmau5"`.
    ///
    /// Deliberately narrower than `MultiValueParser.splitAmbiguous`: that splits on `", "`
    /// and `" x "` too, which would maul legitimate names like
    /// "Tyler, The Creator". Only the unambiguous delimiters the app itself
    /// writes are honoured here.
    static func primaryCredit(_ raw: String) -> String {
        guard let pieces = explicitlySeparated(raw), let lead = pieces.first else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lead
    }

    /// Canonical storage form for a list of explicitly-defined artists.
    /// Uses `" ; "` (space-semicolon-space) so the file tag remains readable
    /// in third-party editors while still being machine-parseable.
    static func joinExplicit(_ artists: [String]) -> String {
        artists
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ; ")
    }

    /// Display form for a credit string. Explicit lists render as
    /// `"A, B, C"`; everything else passes through unchanged.
    static func displayString(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let pieces = explicitlySeparated(raw) {
            return pieces.joined(separator: ", ")
        }
        return raw
    }

    /// Returns the canonical keys this credit string resolves to, deduped
    /// while preserving order.
    func keys(forCredit raw: String?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in split(raw) {
            let k = Self.key(for: piece)
            if seen.insert(k).inserted { out.append(k) }
        }
        return out
    }
}
