import Foundation
import os

/// Saved answers from the ambiguous-credit review ("Simon & Garfunkel": keep
/// it whole; "Artist A, Artist B": split it), keyed by the raw credit string
/// and applied on every scan. Lives beside the other library sidecars at
/// `<root>/.flactastic/split-decisions.json`, so the answers travel with the
/// music folder.
///
/// Same ownership model as `TrackIDStore`: a plain helper owned by the
/// `@MainActor` `LibraryStore`.
final class SplitDecisionStore {
    private static let log = Logger(subsystem: "flactastic", category: "SplitDecisionStore")
    /// Upper bound on stored answers, so a corrupt or hostile sidecar can't
    /// balloon memory.
    private static let maxEntries = 100_000

    private(set) var decisions: [String: MultiValueParser.Decision] = [:]
    private var sidecarURL: URL?

    func load(from rootURL: URL) {
        let url = rootURL.appendingPathComponent(".flactastic", isDirectory: true)
            .appendingPathComponent("split-decisions.json")
        sidecarURL = url
        decisions = [:]
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: MultiValueParser.Decision].self, from: data)
            decisions = Self.sanitized(decoded)
        } catch {
            Self.log.error("Couldn't read split decisions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records answers (later ones win) and saves once.
    func record(_ answers: [String: MultiValueParser.Decision]) {
        guard !answers.isEmpty else { return }
        decisions.merge(Self.sanitized(answers)) { _, new in new }
        save()
    }

    private func save() {
        guard let url = sidecarURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(decisions).write(to: url, options: .atomic)
        } catch {
            Self.log.error("Couldn't save split decisions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops over-long keys and caps split lists, since the file is read back
    /// as untrusted input.
    private static func sanitized(_ input: [String: MultiValueParser.Decision]) -> [String: MultiValueParser.Decision] {
        var out: [String: MultiValueParser.Decision] = [:]
        for (raw, decision) in input where raw.count <= MultiValueParser.maxValueLength {
            guard out.count < maxEntries else { break }
            switch decision {
            case .keep: out[raw] = .keep
            case .split(let parts):
                let clean = MultiValueParser.normalize(parts)
                out[raw] = clean.count > 1 ? .split(clean) : .keep
            }
        }
        return out
    }
}
