import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Review repository", .serialized)
struct ReviewRepositoryTests {

    /// Late Night Drive (one way): 2 close matches. Garden Sundays (both ways): 1 removal, 1 kept removal.
    private func makeStore() throws -> (ModelContainer, late: UUID, garden: UUID) {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let late = SyncPair(spotifyPlaylistId: "sp-late", spotifyPlaylistName: "Late Night Drive",
                            appleMusicPlaylistId: "am-late", appleMusicPlaylistName: "Late Night Drive", syncDirection: .spotifyToApple)
        context.insert(late)
        for (n, title) in ["Midnight City", "Pump It"].enumerated() {
            let row = CachedTrack(isrc: "R\(n)", title: title, artist: "Artist", albumName: "Album", durationMs: 243_000,
                                  spotifyTrackUri: "spotify:track:r\(n)", source: .spotify, syncState: .needsReview)
            row.matchConfidence = 86 - n
            row.matchReason = .versionDifference
            row.candidates = [
                MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "c\(n)", title: "\(title) (Remaster)", artist: "Artist"),
                               confidence: 86 - n, reason: .versionDifference),
                MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "live\(n)", title: "\(title) (Live)", artist: "Artist"),
                               confidence: 41, reason: .versionDifference)
            ]
            row.addedAt = Date(timeIntervalSince1970: Double(n))
            row.syncPair = late
            context.insert(row)
        }

        let garden = SyncPair(spotifyPlaylistId: "sp-garden", spotifyPlaylistName: "Garden Sundays",
                              appleMusicPlaylistId: "am-garden", appleMusicPlaylistName: "Garden Sundays", syncDirection: .bidirectional)
        context.insert(garden)
        let holocene = CachedTrack(isrc: "H", title: "Holocene", artist: "Bon Iver", spotifyTrackUri: "spotify:track:holo",
                                   appleMusicTrackId: "i.holo", source: .spotify, syncState: .synced)
        holocene.removalFlag = .removedFromAppleMusic
        holocene.removalFlaggedAt = Date(timeIntervalSince1970: 1_800_000_000)
        holocene.syncPair = garden
        context.insert(holocene)
        let kept = CachedTrack(isrc: "K", title: "Towers", artist: "Bon Iver", spotifyTrackUri: "spotify:track:k",
                               appleMusicTrackId: "i.k", source: .spotify, syncState: .synced)
        kept.removalFlag = .removedFromAppleMusic
        kept.removalKeptAt = Date()
        kept.syncPair = garden
        context.insert(kept)
        try context.save()
        return (container, late.id, garden.id)
    }

    @Test("Close matches across seams, in playlist order, best candidate first")
    func reviewItems() async throws {
        let (container, late, _) = try makeStore()
        let items = try await SwiftDataSeamRepository(modelContainer: container).reviewItems(seamId: nil)
        #expect(items.map(\.source.title) == ["Midnight City", "Pump It"])
        let first = try #require(items.first)
        #expect(first.seamId == late)
        #expect(first.seamName == "Late Night Drive")
        #expect(first.key == TrackKey(platform: .spotify, id: "spotify:track:r0"))
        #expect(first.best?.confidence == 86)
        #expect(first.candidates.count == 2)
        #expect(first.targetPlatform == .appleMusic)
    }

    @Test("Review items can be limited to one seam")
    func reviewItemsForSeam() async throws {
        let (container, _, garden) = try makeStore()
        #expect(try await SwiftDataSeamRepository(modelContainer: container).reviewItems(seamId: garden).isEmpty)
    }

    @Test("Two-way removals waiting for an answer; kept differences are left alone")
    func conflicts() async throws {
        let (container, _, garden) = try makeStore()
        let conflicts = try await SwiftDataSeamRepository(modelContainer: container).conflicts(seamId: nil)
        #expect(conflicts.count == 1)
        let holocene = try #require(conflicts.first)
        #expect(holocene.seamId == garden)
        #expect(holocene.conflict.track.title == "Holocene")
        #expect(holocene.conflict.removedFrom == .appleMusic)
        #expect(holocene.conflict.remaining?.id == "spotify:track:holo")
        #expect(holocene.conflict.removed?.id == "i.holo")
        #expect(holocene.remainingPlaylistName == "Garden Sundays")
        #expect(holocene.conflict.noticedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }
}
