import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Seam repository", .serialized)
struct SeamRepositoryTests {

    private func makeStore() throws -> (ModelContainer, UUID) {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Late Night Drive",
                            appleMusicPlaylistId: "p.am", appleMusicPlaylistName: "Late Night Drive",
                            syncDirection: .spotifyToApple)
        pair.isMonitored = true
        pair.lastSyncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(pair)
        for n in 0..<3 {
            let t = CachedTrack(isrc: "I\(n)", title: "Track \(n)", artist: "Kavinsky",
                                spotifyTrackUri: "spotify:track:\(n)", appleMusicTrackId: "i.\(n)",
                                source: .both, syncState: .synced)
            t.addedAt = Date(timeIntervalSince1970: Double(n))
            t.syncPair = pair
            context.insert(t)
        }
        let review = CachedTrack(isrc: "R", title: "Midnight City", artist: "M83",
                                 spotifyTrackUri: "spotify:track:r", source: .spotify, syncState: .needsReview)
        review.matchConfidence = 86
        review.addedAt = Date(timeIntervalSince1970: 10)
        review.syncPair = pair
        context.insert(review)
        let extra = CachedTrack(isrc: "X", title: "Only on Apple Music", artist: "A",
                                appleMusicTrackId: "i.x", source: .appleMusic, syncState: .synced)
        extra.removalFlag = .extraOnDestination
        extra.syncPair = pair
        context.insert(extra)

        let log = SyncLog(action: .monitorSync, tracksAdded: 1)
        log.syncPair = pair
        context.insert(log)
        let change = SyncChange(platform: .appleMusic, kind: .add,
                                track: CatalogTrack(platform: .appleMusic, id: "i.2", title: "Track 2", artist: "Kavinsky"))
        change.run = log
        context.insert(change)
        try context.save()
        return (container, pair.id)
    }

    @Test("Summaries carry names, direction, monitoring and counts")
    func summaries() async throws {
        let (container, id) = try makeStore()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let seam = try #require(try await repository.seams().first)
        #expect(seam.id == id)
        #expect(seam.name == "Late Night Drive")
        #expect(seam.direction == .spotifyToApple)
        #expect(seam.source == .spotify)
        #expect(seam.isMonitored)
        #expect(seam.counts == SeamCounts(synced: 3, review: 1, missing: 0, total: 4))
        #expect(seam.lastCheckedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Detail lists the seam's tracks in playlist order, without target-only extras")
    func detailTracks() async throws {
        let (container, id) = try makeStore()
        let detail = try #require(try await SwiftDataSeamRepository(modelContainer: container).detail(for: id))
        #expect(detail.tracks.map(\.title) == ["Track 0", "Track 1", "Track 2", "Midnight City"])
        #expect(detail.tracks.last?.state == .review(confidence: 86, reason: nil))
    }

    @Test("Tracks Antiphon added recently are marked new")
    func newTracks() async throws {
        let (container, id) = try makeStore()
        let detail = try #require(try await SwiftDataSeamRepository(modelContainer: container).detail(for: id))
        #expect(detail.tracks.filter(\.isNew).map(\.title) == ["Track 2"])
    }

    @Test("Each track says which side it came from")
    func trackOrigins() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Antiphon Test", appleMusicPlaylistId: "p.am",
                            appleMusicPlaylistName: "Antiphon Test", syncDirection: .bidirectional)
        context.insert(pair)
        func row(_ title: String, source: TrackSource, uri: String?, am: String?, order: Double) {
            let t = CachedTrack(isrc: title, title: title, artist: "A", spotifyTrackUri: uri, appleMusicTrackId: am,
                                source: source, syncState: .synced)
            t.addedAt = Date(timeIntervalSince1970: order)
            t.syncPair = pair
            context.insert(t)
        }
        row("From Spotify, not synced yet", source: .spotify, uri: "spotify:track:1", am: nil, order: 1)
        row("Copied from Apple Music", source: .both, uri: "spotify:track:2", am: "i.2", order: 2)
        row("Copied from Spotify", source: .both, uri: "spotify:track:3", am: "1440", order: 3)
        row("On both from the start", source: .both, uri: "spotify:track:4", am: "i.4", order: 4)
        let log = SyncLog(action: .manualSync, tracksAdded: 2)
        log.syncPair = pair
        context.insert(log)
        for (platform, id) in [(Platform.spotify, "spotify:track:2"), (.appleMusic, "1440")] {
            let change = SyncChange(platform: platform, kind: .add, track: CatalogTrack(platform: platform, id: id, title: "x", artist: "A"))
            change.run = log
            context.insert(change)
        }
        try context.save()

        let detail = try #require(try await SwiftDataSeamRepository(modelContainer: container).detail(for: pair.id))
        #expect(detail.tracks.map(\.origin) == [.spotify, .appleMusic, .spotify, .spotify])
    }

    @Test("In an Apple Music → Spotify seam, tracks on both sides came from Apple Music")
    func oneWayOrigin() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "A", appleMusicPlaylistId: "p.am",
                            appleMusicPlaylistName: "A", syncDirection: .appleToSpotify)
        context.insert(pair)
        let t = CachedTrack(isrc: "I", title: "T", artist: "A", spotifyTrackUri: "spotify:track:1", appleMusicTrackId: "i.1",
                            source: .both, syncState: .synced)
        t.syncPair = pair
        context.insert(t)
        try context.save()
        let detail = try #require(try await SwiftDataSeamRepository(modelContainer: container).detail(for: pair.id))
        #expect(detail.tracks.first?.origin == .appleMusic)
    }

    @Test("Rules round-trip, with safe defaults for migrated seams")
    func rules() async throws {
        let (container, id) = try makeStore()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        var rules = try #require(try await repository.rules(for: id))
        #expect(rules.removalPolicy == .keep)
        #expect(rules.isPaused == false)

        rules.removalPolicy = .mirror
        rules.monitorIntervalMinutes = 60
        rules.isPaused = true
        try await repository.update(rules, for: id)

        let stored = try #require(try await repository.rules(for: id))
        #expect(stored.removalPolicy == .mirror)
        #expect(stored.monitorIntervalMinutes == 60)
        #expect(stored.isPaused)
    }

    @Test("Unlinking removes the seam and its history, nothing else")
    func unlink() async throws {
        let (container, id) = try makeStore()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        try await repository.unlink(id)
        #expect(try await repository.seams().isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<CachedTrack>()) == 0)
    }
}
