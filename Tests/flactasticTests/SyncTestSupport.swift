import Foundation

// Shared helpers for the sync tests.
//
// The loopback tests all have the same shape: a listener callback runs the
// far side of a connection on its own task, and the test body needs whatever
// that task produced. These two actors are the handoff, and live here rather
// than being redeclared in each test file.

/// A single value written by a background task and awaited by the test body.
actor AsyncBox<T: Sendable> {
    private var stored: T?

    func set(_ value: T) { stored = value }
    func value() -> T? { stored }

    /// Polls until the value appears or the timeout elapses. Polling rather
    /// than a continuation because the producer is a detached listener
    /// callback that may never run at all when a test is asserting failure.
    func waitForValue(timeout: Duration = .seconds(30)) async -> T? {
        var waited = Duration.zero
        while stored == nil && waited < timeout {
            try? await Task.sleep(for: .milliseconds(50))
            waited += .milliseconds(50)
        }
        return stored
    }
}

/// An append-only list written by a background task.
actor AsyncCollector<T: Sendable> {
    private var items: [T] = []

    func append(_ item: T) { items.append(item) }
    func count() -> Int { items.count }
    func all() -> [T] { items }
}
