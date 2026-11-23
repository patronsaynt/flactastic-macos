import CoreServices
import Foundation

/// Calls `onChange` (on the main actor) a moment after files change anywhere
/// under a folder, once per burst of changes. Changes inside hidden folders
/// (`.flactastic`) are ignored.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "flactastic.folder-watcher", qos: .utility)
    private let onChange: @MainActor @Sendable () -> Void
    private let delay: TimeInterval
    private let rootPath: String
    private var pending: DispatchWorkItem?

    init(folder: URL, delay: TimeInterval = 3, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        self.delay = delay
        self.rootPath = folder.standardizedFileURL.path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: watcher.isVisible) { watcher.changed() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Whether a changed path is outside any hidden folder under the root.
    private func isVisible(_ path: String) -> Bool {
        let inside = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        return !inside.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// On `queue`: restarts the quiet period.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in Task { @MainActor in onChange() } }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync { pending?.cancel() }
    }

    deinit { stop() }
}
