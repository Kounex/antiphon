import Foundation

/// Free-text catalog search, for picking another version by hand.
protocol CatalogSearchService: Sendable {
    func search(_ text: String, on platform: Platform) async throws -> [CatalogTrack]
}

struct LiveCatalogSearchService: CatalogSearchService {
    let spotifyClient: SpotifyAPIClient
    let appleMusicManager: AppleMusicManager

    func search(_ text: String, on platform: Platform) async throws -> [CatalogTrack] {
        switch platform {
        case .spotify: try await SpotifyTrackCatalog(client: spotifyClient).search(text, limit: 10)
        case .appleMusic: try await AppleMusicTrackCatalog(manager: appleMusicManager).search(text, limit: 10)
        }
    }
}

#if DEBUG
struct PreviewCatalogSearchService: CatalogSearchService {
    func search(_ text: String, on platform: Platform) async throws -> [CatalogTrack] {
        ["", " (Live)", " (Acoustic)"].enumerated().map { n, suffix in
            CatalogTrack(platform: platform, id: "search-\(n)", title: "\(text.capitalized)\(suffix)", artist: "M83",
                         album: "Search result \(n + 1)", durationMs: 243_000 + n * 9_000)
        }
    }
}
#endif
