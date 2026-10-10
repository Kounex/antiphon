import Foundation
import MusicKit
import Synchronization

// MARK: - Conversions

extension CatalogTrack {
    init(_ track: SpotifyTrack) {
        self.init(
            platform: .spotify, id: track.uri, title: track.name, artist: track.primaryArtist,
            album: track.album?.name, durationMs: track.durationMs, isrc: track.isrc,
            isExplicit: track.explicit,
            releaseYear: track.album?.releaseDate.flatMap { Int($0.prefix(4)) },
            artworkURL: track.album?.images?.first?.url
        )
    }

    init(_ song: Song) {
        self.init(
            platform: .appleMusic, id: song.id.rawValue, title: song.title, artist: song.artistName,
            album: song.albumTitle, durationMs: song.duration.map { Int($0 * 1000) }, isrc: song.isrc,
            isExplicit: song.contentRating.map { $0 == .explicit },
            releaseYear: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
            artworkURL: song.artwork?.url(width: 300, height: 300)?.absoluteString,
            previewURL: song.previewAssets?.first?.url?.absoluteString
        )
    }

    init(_ info: AppleMusicTrackInfo) {
        self.init(
            platform: .appleMusic, id: info.id, title: info.title, artist: info.artist,
            album: info.albumName, durationMs: info.durationMs, isrc: info.isrc, artworkURL: info.artworkURL
        )
    }
}

extension SpotifyTrack {
    /// A minimal track for a planned match: the engine only needs the URI
    /// (and ISRC/name for its already-in-playlist check).
    init(catalog track: CatalogTrack) {
        self.init(
            id: track.id.components(separatedBy: ":").last, name: track.title, uri: track.id,
            durationMs: track.durationMs ?? 0, explicit: track.isExplicit, popularity: nil, album: nil,
            artists: [SpotifyArtist(id: nil, name: track.artist)],
            externalIds: SpotifyExternalIds(isrc: track.isrc, ean: nil, upc: nil),
            externalUrls: nil, type: "track"
        )
    }
}

// MARK: - Spotify

/// `TrackCatalog` over the existing `SpotifyAPIClient`.
struct SpotifyTrackCatalog: TrackCatalog {
    let client: SpotifyAPIClient
    var platform: Platform { .spotify }

    /// Every release with this ISRC (up to Spotify's Development Mode cap
    /// of 10), not just the first, so the original album can win.
    func tracks(withISRC isrc: String) async throws -> [CatalogTrack] {
        try await client.search(query: "isrc:\(isrc)", limit: 10)
            .filter { $0.isrc?.lowercased() == isrc.lowercased() }
            .map(CatalogTrack.init)
    }

    func search(_ query: String, limit: Int) async throws -> [CatalogTrack] {
        try await client.search(query: query, limit: limit).map(CatalogTrack.init)
    }
}

// MARK: - Apple Music

/// `TrackCatalog` over the existing `AppleMusicManager`, with batched ISRC
/// prefetching (25 per request, as the engine's Stage B does).
final class AppleMusicTrackCatalog: TrackCatalog, Sendable {
    let manager: AppleMusicManager
    var platform: Platform { .appleMusic }
    private let prefetched = Mutex<[String: [CatalogTrack]]>([:])

    init(manager: AppleMusicManager) {
        self.manager = manager
    }

    /// Looks up many ISRCs in a few requests. Failed batches fall back to
    /// per-track lookups later.
    func prefetch(isrcs: [String]) async {
        let wanted = Set(isrcs.filter { !$0.isEmpty && !$0.hasPrefix("local-") })
        for batch in Array(wanted).chunked(into: 25) {
            do {
                let response = try await MusicCatalogResourceRequest<Song>(matching: \.isrc, memberOf: batch).response()
                #if DEBUG
                print("[AppleMusicTrackCatalog] Prefetch: \(batch.count) ISRCs → \(response.items.count) songs, more: \(response.items.hasNextBatch)")
                #endif
                var found: [String: [CatalogTrack]] = Dictionary(uniqueKeysWithValues: batch.map { ($0.lowercased(), []) })
                for song in response.items {
                    guard let isrc = song.isrc?.lowercased() else { continue }
                    found[isrc, default: []].append(CatalogTrack(song))
                }
                prefetched.withLock { $0.merge(found) { _, new in new } }
            } catch {
                print("[AppleMusicTrackCatalog] Batch ISRC prefetch failed: \(error.localizedDescription)")
            }
        }
    }

    func tracks(withISRC isrc: String) async throws -> [CatalogTrack] {
        if let cached = prefetched.withLock({ $0[isrc.lowercased()] }) { return cached }
        return try await manager.searchAllByISRC(isrc).map(CatalogTrack.init)
    }

    func search(_ query: String, limit: Int) async throws -> [CatalogTrack] {
        try await manager.searchCatalog(query: query, limit: limit).map(CatalogTrack.init)
    }
}
