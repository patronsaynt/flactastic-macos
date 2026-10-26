import Foundation

/// One renderable line of lyrics. `timestamp == nil` indicates an unsynced
/// (plain-text) source.
struct LyricsLine: Sendable, Equatable {
    let timestamp: TimeInterval?
    let text: String
}

/// Parsed lyrics — either time-synced (LRC) or plain-text.
struct Lyrics: Sendable, Equatable {
    let lines: [LyricsLine]
    let isSynced: Bool

    /// Returns the index of the line that should be active at `time`. For
    /// synced lyrics this is the most recent line whose timestamp is ≤ time.
    /// Returns 0 when nothing has played yet, nil when there are no lines.
    func currentLineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        // Most recent timestamp ≤ time. Lines are sorted by timestamp at parse.
        var idx = 0
        for (i, line) in lines.enumerated() {
            guard let ts = line.timestamp else { continue }
            if ts <= time { idx = i } else { break }
        }
        return idx
    }

    // MARK: - Construction

    /// Parse an LRC-format string. Supports multi-timestamp lines
    /// (e.g. `[00:01.00][00:05.00]Lyric`), `[mm:ss]` and `[mm:ss.xx]`,
    /// and skips metadata tags like `[ar:Artist]`, `[ti:Title]`,
    /// `[al:Album]`, `[length:03:21]`. An `[offset:±ms]` tag is applied:
    /// positive values make lyrics appear sooner, per the LRC convention.
    static func parseLRC(_ raw: String) -> Lyrics {
        var out: [LyricsLine] = []
        var offset: TimeInterval = 0
        for rawLine in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            var rest = line[...]
            var timestamps: [TimeInterval] = []

            // Pull all leading "[...]" tags.
            while let open = rest.firstIndex(of: "["),
                  open == rest.startIndex,
                  let close = rest.firstIndex(of: "]"),
                  close > open {
                let inside = rest[rest.index(after: open)..<close]
                if let ts = parseTimestamp(String(inside)) {
                    timestamps.append(ts)
                } else if let ms = parseOffsetTag(String(inside)) {
                    offset = ms / 1000
                }
                // Also drops metadata tags ([ar:...], [ti:...], etc.) — they
                // don't parse as timestamps so they're silently discarded.
                rest = rest[rest.index(after: close)...]
            }

            let text = String(rest).trimmingCharacters(in: .whitespaces)
            // Keep empty timestamped lines as visual gaps.
            for ts in timestamps {
                out.append(LyricsLine(timestamp: ts, text: text))
            }
        }
        if offset != 0 {
            out = out.map { LyricsLine(timestamp: $0.timestamp.map { max(0, $0 - offset) }, text: $0.text) }
        }
        out.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        return Lyrics(lines: out, isSynced: !out.isEmpty)
    }

    /// Build pseudo-synced lyrics from plain text by distributing lines
    /// uniformly across `duration`. Used when only `plainLyrics` is available.
    static func fromPlainText(_ raw: String, duration: TimeInterval) -> Lyrics {
        let raw = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard !parts.isEmpty else { return Lyrics(lines: [], isSynced: false) }
        let total = max(duration, 1)
        let step = total / Double(parts.count)
        let lines = parts.enumerated().map { (i, text) in
            LyricsLine(timestamp: Double(i) * step,
                       text: text.trimmingCharacters(in: .whitespaces))
        }
        return Lyrics(lines: lines, isSynced: false)
    }

    /// Re-emit a list of optionally-timestamped lines as LRC. Stamped pairs
    /// render as `[mm:ss.xx]Text`; unstamped pairs render as plain text on
    /// their own line so partial syncing round-trips without losing the
    /// user's input. Format matches the de-facto LRC convention.
    static func serializeLRC(lines: [(TimeInterval?, String)]) -> String {
        lines.map { ts, text -> String in
            guard let ts, ts >= 0 else { return text }
            let minutes = Int(ts) / 60
            let seconds = ts.truncatingRemainder(dividingBy: 60)
            return String(format: "[%02d:%05.2f]%@", minutes, seconds, text)
        }
        .joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Parse `mm:ss[.xx]`. Also accepts the `mm:ss:xx` and `mm:ss,xx`
    /// variants some editors write. Returns nil for non-numeric content
    /// (which is how metadata tags get filtered out).
    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let m = Int(parts[0]), m >= 0 else { return nil }
        // Accept "ss", "ss.xx", "ss.xxx", "ss,xx".
        var secField = parts[1].replacingOccurrences(of: ",", with: ".")
        if parts.count == 3 {
            guard !secField.contains("."), parts[2].allSatisfy(\.isNumber), !parts[2].isEmpty else { return nil }
            secField += "." + parts[2]
        }
        guard let sec = Double(secField), sec >= 0 else { return nil }
        return TimeInterval(m) * 60 + sec
    }

    /// `offset:+200` → 200 (milliseconds). Nil for any other tag.
    private static func parseOffsetTag(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "offset" else { return nil }
        return TimeInterval(parts[1].trimmingCharacters(in: .whitespaces))
    }
}
