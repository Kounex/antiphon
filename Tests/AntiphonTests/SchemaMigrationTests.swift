import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Schema migration", .serialized)
struct SchemaMigrationTests {

    /// Writes a store the way 1.2.4 does and returns its URL.
    private func makeV1Store(direction: SyncDirection) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "default.store")

        let container = try ModelContainer(
            for: V1.SyncPair.self, V1.CachedTrack.self, V1.SyncLog.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        let pair = V1.SyncPair(direction: direction)
        context.insert(pair)
        let track = V1.CachedTrack(title: "Nightcall", isrc: "FR0NT1000010")
        track.removalFlag = .removedFromAppleMusic
        track.syncPair = pair
        context.insert(track)
        let log = V1.SyncLog(added: 4)
        log.syncPair = pair
        context.insert(log)
        try context.save()
        return url
    }

    @Test("A 1.2.4 store opens with existing data intact")
    func existingDataSurvives() throws {
        let url = try makeV1Store(direction: .spotifyToApple)
        let context = ModelContext(try SharedModelContainer.make(url: url))

        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)
        #expect(pair.spotifyPlaylistName == "Late Night Drive")
        #expect(pair.syncDirection == .spotifyToApple)
        #expect(pair.isMonitored)

        let track = try #require(pair.cachedTracks.first)
        #expect(track.title == "Nightcall")
        #expect(track.removalFlag == .removedFromAppleMusic)

        let log = try #require(pair.syncLogs.first)
        #expect(log.tracksAdded == 4)
    }

    @Test("New seam, track and run fields start empty or at safe defaults")
    func newFieldsDefault() throws {
        let url = try makeV1Store(direction: .spotifyToApple)
        let context = ModelContext(try SharedModelContainer.make(url: url))
        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)

        #expect(pair.removalPolicy == nil)
        #expect(pair.effectiveRemovalPolicy == .keep)
        #expect(pair.monitorIntervalMinutes == nil)
        #expect(pair.pausedAt == nil)
        #expect(pair.notifyNewTracks == false)
        #expect(pair.spotifyCreatedByAntiphon == false)

        let track = try #require(pair.cachedTracks.first)
        #expect(track.matchConfidence == nil)
        #expect(track.matchReason == nil)
        #expect(track.candidates.isEmpty)

        let log = try #require(pair.syncLogs.first)
        #expect(log.trigger == nil)
        #expect(log.tracksMoved == 0)
        #expect(log.undoneAt == nil)
        #expect(log.changes.isEmpty)
    }

    @Test("A migrated two-way seam asks before removing")
    func twoWayDefaultsToAsk() throws {
        let url = try makeV1Store(direction: .bidirectional)
        let context = ModelContext(try SharedModelContainer.make(url: url))
        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)
        #expect(pair.effectiveRemovalPolicy == .ask)
    }

    @Test("Changes and problems can be recorded against migrated rows")
    func newModelsAttach() throws {
        let url = try makeV1Store(direction: .spotifyToApple)
        let context = ModelContext(try SharedModelContainer.make(url: url))
        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)
        let log = try #require(pair.syncLogs.first)

        let change = SyncChange(
            platform: .appleMusic, kind: .add,
            track: CatalogTrack(platform: .appleMusic, id: "i.123", title: "Nightcall", artist: "Kavinsky"),
            confidence: 100, reason: .isrc
        )
        change.run = log
        context.insert(change)

        let problem = SyncProblem(kind: .playlistDeleted, platform: .appleMusic, message: "Vinyl Rips was deleted")
        problem.pair = pair
        context.insert(problem)
        try context.save()

        #expect(log.changes.count == 1)
        #expect(pair.problems.count == 1)

        // Deleting the seam takes its problems with it.
        context.delete(pair)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SyncProblem>()) == 0)
    }
}
