import Foundation
import os

/// Times one play or seek, from the user's action to audio at the output:
/// a signpost interval per action (Instruments › os_signpost, "Playback")
/// and one log line with each step's time since the action.
enum PlaybackTrace {
    static let signposter = OSSignposter(subsystem: "flactastic", category: "Playback")
    private static let log = Logger(subsystem: "flactastic", category: "Playback")

    private struct State {
        var label = ""
        var start: ContinuousClock.Instant?
        var interval: OSSignpostIntervalState?
        var id = OSSignpostID.invalid
        var marks: [(String, Double)] = []
        var finished: [String: Double] = [:]
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// The user started a track ("play") or moved the playhead ("seek").
    static func begin(_ label: String) {
        let id = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Action", id: id, "\(label)")
        state.withLock { s in
            if let old = s.interval { signposter.endInterval("Action", old) }
            s = State(label: label, start: .now, interval: interval, id: id, finished: s.finished)
        }
    }

    /// A step of the current action: "request", "headers", "decoded",
    /// "output". Only the first of each counts; "output" ends the action.
    static func mark(_ step: String) {
        let report: String? = state.withLock { s in
            guard let start = s.start, !s.marks.contains(where: { $0.0 == step }) else { return nil }
            let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
                + Double((ContinuousClock.now - start).components.seconds) * 1000
            s.marks.append((step, ms))
            signposter.emitEvent("Step", id: s.id, "\(step)")
            guard step == "output" else { return nil }
            if let interval = s.interval { signposter.endInterval("Action", interval) }
            s.finished = Dictionary(s.marks, uniquingKeysWith: { a, _ in a })
            s.start = nil
            s.interval = nil
            return "\(s.label): " + s.marks.map { "\($0.0) \(String(format: "%.0f", $0.1)) ms" }.joined(separator: ", ")
        }
        if let report { log.info("\(report, privacy: .public)") }
    }

    /// The last finished action's steps, in ms since the action (for tests).
    static var lastFinished: [String: Double] { state.withLock { $0.finished } }
}
