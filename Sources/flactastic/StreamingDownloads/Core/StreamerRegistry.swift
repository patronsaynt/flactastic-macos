import Foundation
import Observation

/// Routes URLs by hostname and aggregates searches across all configured
/// providers. Owns the live `StreamerProvider` instances; rebuild it (or call
/// `replace(provider:)`) after the user edits credentials in Settings.
@Observable
@MainActor
final class StreamerRegistry {
    private(set) var providers: [String: any StreamerProvider] = [:]   // serviceID → provider

    func register(_ provider: any StreamerProvider) {
        providers[provider.serviceID] = provider
    }

    func provider(serviceID: String) -> (any StreamerProvider)? {
        providers[serviceID]
    }

    /// Returns the provider whose `hostnames` match `url.host`, or `nil`.
    /// Compares case-insensitively and tolerates a leading `www.` on either side.
    func provider(for url: URL) -> (any StreamerProvider)? {
        guard let host = url.host?.lowercased() else { return nil }
        let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        for provider in providers.values {
            for h in provider.hostnames {
                let target = h.lowercased()
                let targetNorm = target.hasPrefix("www.") ? String(target.dropFirst(4)) : target
                if normalized == targetNorm { return provider }
            }
        }
        return nil
    }

    /// Resolves a URL to a remote item, picking the right provider by hostname.
    func resolve(_ url: URL) async throws -> RemoteResolveResponse {
        guard let provider = provider(for: url) else {
            throw StreamerError.unsupportedURL(url)
        }
        return try await provider.resolve(url)
    }
}
