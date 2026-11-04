import os

/// Signposts for Instruments' Points of Interest track: the moments and
/// main-thread passes worth lining up against hitches. Free when no trace
/// is recording.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.flactastic.app", category: .pointsOfInterest)

    static func event(_ name: StaticString, _ detail: String = "") {
        signposter.emitEvent(name, "\(detail, privacy: .public)")
    }

    static func begin(_ name: StaticString, _ detail: String = "") -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(detail, privacy: .public)")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Times one synchronous pass.
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(name) { try work() }
    }
}
