import Foundation
import Testing
@testable import flactastic

// The old Spotify client-secret sign-in left its credentials in the
// preferences plist; Settings removes them on launch.

@Test func legacySpotifyCredentialsAreRemoved() throws {
    let suite = "flactastic.tests.legacyCredentials.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("secret", forKey: "flactastic.spotifyClientSecret")
    defaults.set("client", forKey: "flactastic.spotifyClientID")
    defaults.set("token", forKey: "flactastic.spotify.refreshToken")

    Settings.removeLegacyCredentials(from: defaults)

    #expect(defaults.object(forKey: "flactastic.spotifyClientSecret") == nil)
    #expect(defaults.object(forKey: "flactastic.spotifyClientID") == nil)
    // The current PKCE sign-in's token is left alone.
    #expect(defaults.string(forKey: "flactastic.spotify.refreshToken") == "token")
}
