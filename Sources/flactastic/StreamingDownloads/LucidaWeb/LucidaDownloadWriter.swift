import Foundation
import WebKit

/// Adapts `WKDownload` (writes to a file, reports `Progress`) to the
/// `DownloadStream` chunk-based contract `DownloadCoordinator` expects.
///
/// Why bother routing through WKDownload at all: the lucida.to file CDN sits
/// behind Cloudflare with the same bot challenge as the API. WKDownload
/// inherits the WKWebView's cookies + TLS fingerprint, so it sails through
/// where a raw URLSession would 404.
///
/// Flow:
///  1. Provider creates a writer, calls `webView.startDownload(...)` and
///     attaches the writer as delegate.
///  2. WKDownload calls `decideDestinationUsing` once headers arrive — we
///     capture the suggested extension / MIME / size and resume any
///     `awaitResponse()` waiter so the provider can build a correctly-typed
///     `DownloadStream` (extension matters: TagLib dispatches by extension,
///     so calling MP3 bytes ".flac" will fail the tagging step).
///  3. As bytes flow into the temp file we KVO `Progress.completedUnitCount`,
///     read newly-flushed tail bytes and yield them to the
///     `AsyncThrowingStream` the provider already returned.
///  4. `didFinish` drains the rest and finishes the stream.
@MainActor
final class LucidaDownloadWriter: NSObject, WKDownloadDelegate {

    /// Snapshot of headers that arrives in `decideDestinationUsing`.
    struct ResponseInfo: Sendable {
        let suggestedExtension: String
        let mimeType: String
        let sizeBytes: Int64?
    }

    /// Live byte stream — created up front so it's safe to yield into from
    /// the moment the first chunk hits disk, even before the provider has
    /// wrapped it in a `DownloadStream`.
    let bytesStream: AsyncThrowingStream<Data, Error>
    private let bytesContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private var responseInfo: ResponseInfo?
    private var responseError: Error?
    private var responseWaiters: [CheckedContinuation<ResponseInfo, Error>] = []

    private var tempURL: URL?
    private var readHandle: FileHandle?
    private var observation: NSKeyValueObservation?
    private var lastOffset: UInt64 = 0
    /// Weak ref so `tearDown()` (called on stream cancellation) can abort
    /// the in-flight WKDownload — otherwise the network transfer keeps
    /// running until the file is fully fetched even after the user cancels.
    private weak var activeDownload: WKDownload?

    override init() {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.bytesStream = AsyncThrowingStream<Data, Error> { cont = $0 }
        self.bytesContinuation = cont
        super.init()
        self.bytesContinuation.onTermination = { @Sendable _ in
            Task { @MainActor in self.tearDown() }
        }
    }

    /// Suspend until headers arrive (or fail with the download's error).
    /// Idempotent — repeat calls after the response is in just return it.
    func awaitResponse() async throws -> ResponseInfo {
        if let r = responseInfo { return r }
        if let e = responseError { throw e }
        return try await withCheckedThrowingContinuation { c in
            responseWaiters.append(c)
        }
    }

    /// Build the `DownloadStream` that the coordinator will iterate.
    func downloadStream(using info: ResponseInfo) -> DownloadStream {
        DownloadStream(
            bytes: bytesStream,
            mimeType: info.mimeType,
            sizeBytes: info.sizeBytes,
            suggestedExtension: info.suggestedExtension
        )
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let dir = FileManager.default.temporaryDirectory
        // Prefer the server-suggested filename's extension; fall back to a
        // best-effort guess from MIME so we never write `.bin` into the
        // library when we know better.
        let suggestedExt = (suggestedFilename as NSString).pathExtension.lowercased()
        let mt = response.mimeType ?? "application/octet-stream"
        let ext = suggestedExt.isEmpty ? Self.guessExt(mime: mt) : suggestedExt
        let stem = "flac-lucida-\(UUID().uuidString)"
        let dest = dir.appendingPathComponent("\(stem).\(ext)")
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil

        let info = ResponseInfo(suggestedExtension: ext, mimeType: mt, sizeBytes: total)
        self.tempURL = dest
        self.responseInfo = info
        let waiters = responseWaiters
        responseWaiters.removeAll()
        for w in waiters { w.resume(returning: info) }
        installObservation(on: download, file: dest)
        return dest
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in self.finalizeAndClose() }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error,
                              resumeData: Data?) {
        Task { @MainActor in
            // If we never got headers, fail the awaitResponse() waiter too;
            // otherwise just terminate the byte stream.
            self.responseError = error
            let waiters = self.responseWaiters
            self.responseWaiters.removeAll()
            for w in waiters { w.resume(throwing: error) }
            self.bytesContinuation.finish(throwing: error)
            self.tearDown()
        }
    }

    // MARK: - File tailing

    private func installObservation(on download: WKDownload, file: URL) {
        self.activeDownload = download
        Task { @MainActor [self] in
            // WKDownload may not have created the file yet at this exact
            // instant; give it a brief window to appear before observing.
            for _ in 0..<20 where !FileManager.default.fileExists(atPath: file.path) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.readHandle = try? FileHandle(forReadingFrom: file)
            self.observation = download.progress.observe(
                \.completedUnitCount, options: [.new]
            ) { [weak self] _, _ in
                Task { @MainActor in self?.drain() }
            }
            self.drain()  // first read in case bytes arrived before we attached
        }
    }

    private func drain() {
        guard let handle = readHandle else { return }
        do {
            try handle.seek(toOffset: lastOffset)
            let chunk = handle.availableData
            if !chunk.isEmpty {
                lastOffset += UInt64(chunk.count)
                bytesContinuation.yield(chunk)
            }
        } catch {
            bytesContinuation.finish(throwing: error)
            tearDown()
        }
    }

    private func finalizeAndClose() {
        drain()  // flush whatever remains past the last KVO tick
        bytesContinuation.finish()
        tearDown()
    }

    private func tearDown() {
        // Abort the WKDownload if it's still running — fires when the
        // coordinator's Task is cancelled. Pass an empty completion so
        // we don't capture resume data we'll never use.
        if let dl = activeDownload {
            dl.cancel { _ in }
            activeDownload = nil
        }
        observation?.invalidate(); observation = nil
        try? readHandle?.close(); readHandle = nil
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempURL = nil
    }

    // MARK: - MIME → extension

    /// Fallback when the response has no filename. Covers the lossy/lossless
    /// formats lucida.to is likely to deliver across its supported services.
    private static func guessExt(mime: String) -> String {
        let m = mime.lowercased()
        if m.contains("flac")              { return "flac" }
        if m.contains("mpeg") || m.contains("mp3") { return "mp3" }
        if m.contains("mp4") || m.contains("m4a") || m.contains("aac") { return "m4a" }
        if m.contains("opus")              { return "opus" }
        if m.contains("ogg") || m.contains("vorbis") { return "ogg" }
        if m.contains("wav")               { return "wav" }
        return "bin"
    }
}
