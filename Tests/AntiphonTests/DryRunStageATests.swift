import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Dry-run Stage A", .serialized)
@MainActor
struct DryRunStageATests {

    private func spotifyItem(_ n: Int, isrc: String? = nil) throws -> SpotifyPlaylistItem {
        let isrcJSON = isrc.map { "\"external_ids\": {\"isrc\": \"\($0)\"}," } ?? ""
        let json = """
        {"item": {"id": "t\(n)", "name": "Track \(n)", "uri": "spotify:track:t\(n)", "duration_ms": 200000,
                  \(isrcJSON) "type": "track", "artists": [{"name": "Artist \(n)"}]}}
        """
        return try JSONDecoder().decode(SpotifyPlaylistItem.self, from: Data(json.utf8))
    }

    private func appleTrack(_ n: Int, isrc: String? = nil) -> AppleMusicTrackInfo {
        AppleMusicTrackInfo(id: "i.\(n)", title: "Track \(n)", artist: "Artist \(n)", albumName: nil,
                            isrc: isrc, durationMs: 200_000, artworkURL: nil)
    }

    private let matcher = TrackMatcher(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())

    private func seedPair(in container: ModelContainer, direction: SyncDirection, syncedTracks: [Int]) throws -> UUID {
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Workout Mix 2026",
                            appleMusicPlaylistId: "p.am", appleMusicPlaylistName: "Gym Rotation",
                            syncDirection: direction)
        context.insert(pair)
        for n in syncedTracks {
            let track = CachedTrack(isrc: "ISRC\(n)", title: "Track \(n)", artist: "Artist \(n)", durationMs: 200_000,
                                    spotifyTrackUri: "spotify:track:t\(n)", appleMusicTrackId: "i.\(n)",
                                    source: .both, syncState: .synced)
            track.syncPair = pair
            context.insert(track)
        }
        try context.save()
        return pair.id
    }

    private func storedTrackCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<CachedTrack>())
    }

    @Test("First sync: source tracks become pending rows; tracks on both sides are in sync")
    func firstSyncRows() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let pairId = try seedPair(in: container, direction: .spotifyToApple, syncedTracks: [])

        let result = try DryRunStageA.run(
            container: container, pairId: pairId, action: .initialSync, trackMatcher: matcher,
            spotifyTracks: [try spotifyItem(1, isrc: "ISRC1"), try spotifyItem(2, isrc: "ISRC2")],
            appleMusicTracks: [appleTrack(1, isrc: "ISRC1")]
        )

        #expect(result.sourcePlatform == .spotify)
        #expect(result.isInitialSync)
        let byId = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.source.id, $0) })
        #expect(byId["spotify:track:t1"]?.state == .synced)
        #expect(byId["spotify:track:t1"]?.counterpartId == "i.1")
        #expect(byId["spotify:track:t2"]?.state == .pending)
    }

    @Test("A dry run never writes to the store")
    func storeUntouched() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let pairId = try seedPair(in: container, direction: .spotifyToApple, syncedTracks: [1, 2])
        #expect(try storedTrackCount(container) == 2)

        // Track 2 was removed on Spotify, track 3 is new.
        let result = try DryRunStageA.run(
            container: container, pairId: pairId, action: .manualSync, trackMatcher: matcher,
            spotifyTracks: [try spotifyItem(1, isrc: "ISRC1"), try spotifyItem(3, isrc: "ISRC3")],
            appleMusicTracks: [appleTrack(1, isrc: "ISRC1"), appleTrack(2, isrc: "ISRC2")]
        )

        #expect(result.rows.contains { $0.source.id == "spotify:track:t3" && $0.state == .pending })
        #expect(result.rows.contains { $0.source.id == "spotify:track:t2" && $0.removalFlag == .removedFromSource })

        let fresh = ModelContext(container)
        let stored = try fresh.fetch(FetchDescriptor<CachedTrack>())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.removalFlag == nil && $0.syncState == .synced })
    }

    @Test("A first sync that would rebuild the cache leaves the old cache in place")
    func rebuildUntouched() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let pairId = try seedPair(in: container, direction: .spotifyToApple, syncedTracks: [1, 2])

        _ = try DryRunStageA.run(
            container: container, pairId: pairId, action: .fullRebuild, trackMatcher: matcher,
            spotifyTracks: [try spotifyItem(5)], appleMusicTracks: []
        )
        #expect(try storedTrackCount(container) == 2)
    }

    @Test("Two-way seams with an empty Spotify side treat Apple Music as the source")
    func twoWaySourceSide() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let pairId = try seedPair(in: container, direction: .bidirectional, syncedTracks: [])
        let result = try DryRunStageA.run(
            container: container, pairId: pairId, action: .initialSync, trackMatcher: matcher,
            spotifyTracks: [], appleMusicTracks: [appleTrack(1)]
        )
        #expect(result.sourcePlatform == .appleMusic)
        #expect(result.rows.first?.source.platform == .appleMusic)
        #expect(result.removalPolicy == .ask)
    }
}

@Suite("Cover art backfill", .serialized)
@MainActor
struct ArtworkBackfillTests {

    private func spotifyItem(uri: String, image: String) throws -> SpotifyPlaylistItem {
        let json = """
        {"item": {"id": "x", "name": "Snøfall", "uri": "\(uri)", "duration_ms": 200000, "type": "track",
                  "external_ids": {"isrc": "NOX001"}, "artists": [{"name": "Trivium"}],
                  "album": {"id": "a", "name": "Snøfall", "images": [{"url": "\(image)", "height": 640, "width": 640}]}}}
        """
        return try JSONDecoder().decode(SpotifyPlaylistItem.self, from: Data(json.utf8))
    }

    @Test("Library artwork (musicKit://) can't be drawn; it's replaced from the other side")
    func webArtworkCheck() {
        let track = CachedTrack(isrc: "I", title: "T", artist: "A", artworkURL: "musicKit://artwork/transient/300x300/abc", source: .appleMusic)
        #expect(!track.hasWebArtwork)
        track.adoptArtwork(from: CatalogTrack(platform: .spotify, id: "s", title: "T", artist: "A", artworkURL: "https://i.scdn.co/image/abc"))
        #expect(track.artworkURL == "https://i.scdn.co/image/abc")
        // A web cover is never replaced.
        track.adoptArtwork(from: CatalogTrack(platform: .spotify, id: "s", title: "T", artist: "A", artworkURL: "https://other"))
        #expect(track.artworkURL == "https://i.scdn.co/image/abc")
    }

    @Test("A sync fills in the cover for rows that came from Apple Music")
    func alignBackfills() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Antiphon Test", appleMusicPlaylistId: "p.am",
                            appleMusicPlaylistName: "Antiphon Test", syncDirection: .bidirectional)
        context.insert(pair)
        let row = CachedTrack(isrc: "NOX001", title: "Snøfall", artist: "Trivium", artworkURL: "musicKit://artwork/x",
                              spotifyTrackUri: "spotify:track:snow", appleMusicTrackId: "i.snow", source: .both, syncState: .synced)
        row.syncPair = pair
        context.insert(row)
        try context.save()

        let aligned = CacheAligner.alignCache(
            in: context, pair: pair, cachedTracks: [row],
            spotifyTracks: [try spotifyItem(uri: "spotify:track:snow", image: "https://i.scdn.co/image/snow")],
            appleMusicTracks: [], isInitialSync: false, isSpotifySource: true, persist: false
        )
        #expect(aligned.first?.artworkURL == "https://i.scdn.co/image/snow")
    }
}
