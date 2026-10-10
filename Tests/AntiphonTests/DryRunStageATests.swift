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

@Suite("Removal flags across syncs", .serialized)
@MainActor
final class RemovalFlagAlignmentTests {
    /// Keeps each test's store alive for the test's duration.
    private var containers: [ModelContainer] = []

    private func spotifyItem(_ n: Int, isrc: String) throws -> SpotifyPlaylistItem {
        let json = """
        {"item": {"id": "t\(n)", "name": "Word Up!", "uri": "spotify:track:t\(n)", "duration_ms": 200000,
                  "external_ids": {"isrc": "\(isrc)"}, "type": "track", "artists": [{"name": "Korn"}]}}
        """
        return try JSONDecoder().decode(SpotifyPlaylistItem.self, from: Data(json.utf8))
    }

    private func appleTrack(_ n: Int, isrc: String) -> AppleMusicTrackInfo {
        AppleMusicTrackInfo(id: "i.\(n)", title: "Word Up!", artist: "Korn", albumName: nil,
                            isrc: isrc, durationMs: 200_000, artworkURL: nil)
    }

    // MARK: - Removal flags survive a sync on the other side

    private func flaggedRow(_ flag: RemovalFlag, source: TrackSource, kept: Bool = false) throws -> (ModelContext, SyncPair, CachedTrack) {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Antiphon Test", appleMusicPlaylistId: "p.am",
                            appleMusicPlaylistName: "Antiphon Test", syncDirection: .bidirectional)
        context.insert(pair)
        let row = CachedTrack(isrc: "ISRC1", title: "Word Up!", artist: "Korn", spotifyTrackUri: "spotify:track:t1",
                              appleMusicTrackId: "i.1", source: source, syncState: .synced)
        row.removalFlag = flag
        row.removalFlaggedAt = Date()
        if kept { row.removalKeptAt = Date() }
        row.syncPair = pair
        context.insert(row)
        try context.save()
        containers.append(container)
        return (context, pair, row)
    }

    @Test("A removal on Apple Music stays a question while the track is still on Spotify")
    func appleRemovalSurvivesSpotifyPass() throws {
        let (context, pair, row) = try flaggedRow(.removedFromAppleMusic, source: .spotify)
        _ = CacheAligner.alignCache(in: context, pair: pair, cachedTracks: [row], spotifyTracks: [try spotifyItem(1, isrc: "ISRC1")],
                                    appleMusicTracks: [], isInitialSync: false, isSpotifySource: true, persist: false)
        #expect(row.removalFlag == .removedFromAppleMusic)
        #expect(row.removalFlaggedAt != nil)
    }

    @Test("A kept difference stays kept across syncs")
    func keptDifferenceSurvives() throws {
        let (context, pair, row) = try flaggedRow(.removedFromAppleMusic, source: .spotify, kept: true)
        _ = CacheAligner.alignCache(in: context, pair: pair, cachedTracks: [row], spotifyTracks: [try spotifyItem(1, isrc: "ISRC1")],
                                    appleMusicTracks: [], isInitialSync: false, isSpotifySource: true, persist: false)
        #expect(row.removalKeptAt != nil)
        #expect(row.removalFlag == .removedFromAppleMusic)
    }

    @Test("A removal on Spotify stays a question while the track is still on Apple Music")
    func spotifyRemovalSurvivesApplePass() throws {
        let (context, pair, row) = try flaggedRow(.removedFromSpotify, source: .appleMusic)
        _ = CacheAligner.alignCache(in: context, pair: pair, cachedTracks: [row], spotifyTracks: [],
                                    appleMusicTracks: [appleTrack(1, isrc: "ISRC1")], isInitialSync: false, isSpotifySource: false, persist: false)
        #expect(row.removalFlag == .removedFromSpotify)
    }

    @Test("A track back on the source clears its own removal")
    func backOnSourceClears() throws {
        let (context, pair, row) = try flaggedRow(.removedFromSource, source: .both)
        _ = CacheAligner.alignCache(in: context, pair: pair, cachedTracks: [row], spotifyTracks: [try spotifyItem(1, isrc: "ISRC1")],
                                    appleMusicTracks: [], isInitialSync: false, isSpotifySource: true, persist: false)
        #expect(row.removalFlag == nil)
    }
}

@Suite("Removals on the other side")
struct TargetRemovalTests {
    private func row(source: TrackSource, flag: RemovalFlag? = nil, kept: Bool = false) -> CachedTrack {
        let row = CachedTrack(isrc: "ISRC1", title: "Word Up!", artist: "Korn", spotifyTrackUri: "spotify:track:t1",
                              appleMusicTrackId: "i.1", source: source, syncState: .synced)
        row.removalFlag = flag
        if kept { row.removalKeptAt = Date() }
        return row
    }

    @Test("A synced track missing on Apple Music was removed there")
    func both() {
        #expect(DeltaEngine.isRemoved(row(source: .both), from: .appleMusic, live: []))
        #expect(!DeltaEngine.isRemoved(row(source: .both), from: .appleMusic, live: ["i.1"]))
    }

    @Test("A row an earlier version left one-sided is asked about again")
    func strandedRow() {
        #expect(DeltaEngine.isRemoved(row(source: .spotify), from: .appleMusic, live: []))
    }

    @Test("Open questions and kept differences aren't flagged twice")
    func alreadyKnown() {
        #expect(!DeltaEngine.isRemoved(row(source: .spotify, flag: .removedFromAppleMusic), from: .appleMusic, live: []))
        #expect(!DeltaEngine.isRemoved(row(source: .spotify, kept: true), from: .appleMusic, live: []))
    }

    @Test("A track Antiphon just added that Apple Music doesn't list yet isn't a removal")
    func notVisibleYet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let added = row(source: .both)
        added.appleMusicTrackId = "1831584253"   // catalog ID: never seen in a playlist read
        added.lastSyncAttempt = now.addingTimeInterval(-60)
        #expect(!DeltaEngine.isRemoved(added, from: .appleMusic, live: [], now: now))
        // Still missing long after the write: ask.
        added.lastSyncAttempt = now.addingTimeInterval(-DeltaEngine.appleMusicReadGrace - 1)
        #expect(DeltaEngine.isRemoved(added, from: .appleMusic, live: [], now: now))
        // Seen before (library ID): a recent write doesn't hide a real removal.
        let seen = row(source: .both)
        seen.lastSyncAttempt = now.addingTimeInterval(-60)
        #expect(DeltaEngine.isRemoved(seen, from: .appleMusic, live: [], now: now))
    }

    @Test("Spotify works the same way")
    func spotify() {
        #expect(DeltaEngine.isRemoved(row(source: .appleMusic), from: .spotify, live: []))
        #expect(!DeltaEngine.isRemoved(row(source: .both), from: .spotify, live: ["spotify:track:t1"]))
    }
}

@Suite("Anchoring added Apple Music tracks")
struct LibraryAnchorTests {
    private func added(_ catalogID: String, _ title: String, _ artist: String = "Korn", seconds: Int = 173) -> LibraryAnchor.Added {
        .init(catalogID: catalogID, title: title, artist: artist, durationMs: seconds * 1000)
    }

    private func entry(_ libraryID: String, _ catalogID: String?, _ title: String, _ artist: String = "Korn", seconds: Int = 173) -> LibraryAnchor.Entry {
        .init(libraryID: libraryID, catalogID: catalogID, title: title, artist: artist, durationMs: seconds * 1000)
    }

    @Test("Added catalog songs map to the library entries the playlist lists")
    func mapsCatalogToLibrary() {
        let entries = [entry("i.faint", "590423286", "Faint", "Linkin Park"), entry("i.local", nil, "Demo")]
        let ids = LibraryAnchor.libraryIDs(for: [added("590423286", "Faint", "Linkin Park"), added("999", "Elsewhere")], in: entries)
        #expect(ids == ["590423286": "i.faint"])
    }

    @Test("A song already in the library is listed under an equivalent catalog ID")
    func equivalentCatalogID() {
        // Seen on device: added 1831584253, the library entry says 193613943.
        let entries = [entry("i.word", "193613943", "Word Up!"), entry("i.faint", "590423286", "Faint", "Linkin Park")]
        let ids = LibraryAnchor.libraryIDs(for: [added("1831584253", "Word Up!"), added("590423286", "Faint", "Linkin Park")], in: entries)
        #expect(ids == ["1831584253": "i.word", "590423286": "i.faint"])
    }

    @Test("The fallback never takes an entry another added song owns, or a different length")
    func fallbackIsCareful() {
        let entries = [entry("i.word", "1831584253", "Word Up!"), entry("i.live", "555", "Word Up!", seconds: 240)]
        let ids = LibraryAnchor.libraryIDs(for: [added("1831584253", "Word Up!"), added("777", "Word Up!")], in: entries)
        #expect(ids == ["1831584253": "i.word"])
    }
}

@Suite("Removal safety check")
struct RemovalSafetyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func rows(new: Int, open: Int = 0, kept: Int = 0, fine: Int = 0) -> [CachedTrack] {
        func make(_ flag: RemovalFlag?, at: Date?, kept: Bool = false) -> CachedTrack {
            let row = CachedTrack(isrc: UUID().uuidString, title: "T", artist: "A", source: .both, syncState: .synced)
            row.removalFlag = flag
            row.removalFlaggedAt = at
            if kept { row.removalKeptAt = at }
            return row
        }
        return (0..<new).map { _ in make(.removedFromAppleMusic, at: start.addingTimeInterval(1)) }
            + (0..<open).map { _ in make(.removedFromAppleMusic, at: start.addingTimeInterval(-3600)) }
            + (0..<kept).map { _ in make(.removedFromAppleMusic, at: start.addingTimeInterval(-3600), kept: true) }
            + (0..<fine).map { _ in make(nil, at: nil) }
    }

    @Test("A broken read that empties a playlist stops the sync")
    func brokenRead() {
        #expect(RemovalSafety.shouldStop(rows(new: 40, fine: 2), since: start))
        #expect(RemovalSafety.shouldStop(rows(new: 4), since: start))
    }

    @Test("Removing a song or two from a small playlist doesn't")
    func smallPlaylist() {
        #expect(!RemovalSafety.shouldStop(rows(new: 1, kept: 1, fine: 1), since: start))
        #expect(!RemovalSafety.shouldStop(rows(new: 2, fine: 1), since: start))
    }

    @Test("Open questions and kept differences aren't new removals")
    func onlyNewOnes() {
        #expect(!RemovalSafety.shouldStop(rows(new: 1, open: 5, kept: 5, fine: 2), since: start))
        #expect(RemovalSafety.newRemovals(in: rows(new: 1, open: 5, kept: 5), since: start) == 1)
    }
}
