import Foundation
import Testing
@testable import flactastic

// A server that goes away mid-session and comes back. Needs the variables
// ServerIntegrationTests uses, plus FLACTASTIC_TEST_OUTAGE and a caller that
// takes the server away when /tmp/flactastic-outage-start appears (then
// creates /tmp/flactastic-outage-started) and brings it back when
// /tmp/flactastic-outage-end appears (then creates /tmp/flactastic-outage-ended).

private let env = ProcessInfo.processInfo.environment

@Suite(.enabled(if: env["FLACTASTIC_TEST_SERVER"] != nil && env["FLACTASTIC_TEST_OUTAGE"] != nil), .serialized)
@MainActor
struct ServerReconnectTests {
    private func signal(_ name: String) {
        FileManager.default.createFile(atPath: "/tmp/flactastic-outage-\(name)", contents: nil)
    }

    private func wait(for name: String, _ seconds: Double = 60) async {
        let end = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: "/tmp/flactastic-outage-\(name)"), Date() < end {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func until(_ seconds: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @Test("Outage: the session notices, keeps trying, and is ready again once the server is back")
    func reconnectsAfterOutage() async throws {
        for f in ["start", "started", "end", "ended"] { try? FileManager.default.removeItem(atPath: "/tmp/flactastic-outage-\(f)") }
        let address = ServerAddress(typed: env["FLACTASTIC_TEST_SERVER"]!)!
        let user = (env["FLACTASTIC_TEST_USERS"] ?? "").split(separator: ",")[0].split(separator: ":", maxSplits: 1).map(String.init)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flactastic-outage-\(UUID().uuidString)")
        let library = LibraryStore()
        let session = ServerSession(library: library, playlists: PlaylistStore(),
                                    listening: ListeningStore(librariesDirectory: temp.appendingPathComponent("libraries")),
                                    settings: Settings(), writer: MetadataWriter())
        let (info, pin) = try await ServerSession.probe(address)
        try await session.signIn(address: address, info: info, pin: pin, username: user[0], password: user[1],
                                 offlineFolder: temp.appendingPathComponent("offline"))
        let profile = try #require(session.active)
        defer {
            session.deactivate()
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? ServerTokenStore.delete(profile.id)
        }
        await until(20) { session.status == .ready && !library.tracks.isEmpty }
        #expect(session.status == .ready)

        // Something is streaming when the server goes.
        let track = try #require(library.tracks.first)
        let source = try await session.streamer.open(track, at: 0)
        #expect(source != nil)

        let t0 = Date()
        let watcher = Task { @MainActor in
            var last = session.status
            while !Task.isCancelled {
                if session.status != last { last = session.status; print("STATUS \(String(format: "%5.1f", Date().timeIntervalSince(t0))) s: \(last)") }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { watcher.cancel() }
        signal("start")
        await wait(for: "started")
        // Anything that touches the server now notices.
        await session.refreshLibraryInfo()
        await until(90) { session.status == .unreachable }
        #expect(session.status == .unreachable)
        let lost = Date()

        // Clicking the notice while the server is still away doesn't wedge anything.
        session.reconnectNow()

        // A download lands in the offline folder meanwhile: it shows at once,
        // marked as only on this Mac, and waits to upload.
        let title = "Outage \(UUID().uuidString.prefix(6))"
        let folder = URL(fileURLWithPath: profile.offlineFolder).appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(title).flac")
        try FileManager.default.copyItem(at: FixtureSupport.audioDir.appendingPathComponent("cur-single.flac"), to: file)
        let tag = Process()
        tag.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/metaflac")
        tag.arguments = ["--remove-tag=TITLE", "--set-tag=TITLE=\(title)", file.path]
        try tag.run(); tag.waitUntilExit()
        library.refreshLibrary()
        await until(15) { library.tracks.contains { $0.title == title } }
        let waiting = try #require(library.tracks.first { $0.title == title })
        #expect(session.onThisMac(waiting) == .notOnServer)
        #expect(session.status == .unreachable)
        #expect(!session.uploads.items.contains { $0.status == .failed })
        try await Task.sleep(for: .seconds(3))

        signal("end")
        await wait(for: "ended")
        let back = Date()
        await until(90) { session.status == .ready }
        print("OUTAGE \(env["FLACTASTIC_TEST_OUTAGE"]!): lost after start, ready \(String(format: "%.1f", Date().timeIntervalSince(back))) s after the server came back (outage \(String(format: "%.0f", back.timeIntervalSince(lost))) s)")
        #expect(session.status == .ready)

        // The download uploads by itself, and shows once, as the server's
        // track with its copy here.
        await until(60) {
            library.tracks.filter { $0.title == title }.count == 1
                && library.tracks.first { $0.title == title }.map { session.onThisMac($0) == .copy } == true
        }
        let uploaded = library.tracks.filter { $0.title == title }
        #expect(uploaded.count == 1)
        #expect(uploaded.first.map { session.serverID(for: $0) != nil } == true)
        #expect(uploaded.first.map { session.onThisMac($0) } == .copy)
        if let id = uploaded.first.flatMap({ session.serverID(for: $0) }) {
            _ = try? await session.call { try await $0.send("DELETE", "v2/tracks/\(id.uuidString)") }
        }

        let page = try await session.call { try await $0.json(ServerInfo.self, "GET", "v2/server", timeout: 10) }
        #expect(page.id == info.id)
        _ = source
    }
}
