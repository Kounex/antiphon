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
