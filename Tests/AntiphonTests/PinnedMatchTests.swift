import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Picked versions")
struct PinnedMatchTests {

    private func spotify(_ id: String, _ title: String) -> CatalogTrack {
        CatalogTrack(platform: .spotify, id: id, title: title, artist: "Korn", album: "Word Up! (The Remixes)",
                     durationMs: 172_000, isrc: "USSM10411917")
    }

    private func apple(_ id: String, album: String) -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: "Word Up!", artist: "Korn", album: album,
                     durationMs: 172_000, isrc: "USSM10411917")
    }

    private func row(_ track: CatalogTrack) -> PlanRow {
        PlanRow(source: track, counterpartId: nil, state: .pending, removalFlag: nil, removalKept: false, retryCount: 0)
    }

    @Test("A song with a pick is planned from it, without looking it up")
    func pinnedRowSkipsLookup() {
        let picked = row(spotify("s1", "Word Up!"))
        let other = row(spotify("s2", "Freak on a Leash"))
        let pick = apple("ep", album: "Word Up!: The Remixes - EP")

        let split = PinnedPlanning.split([picked, other], pins: [picked.key: pick], targetPlaylists: [:])

        #expect(split.toLookUp.map(\.key) == [other.key])
        let outcome = try? #require(split.outcomes[picked.key])
        #expect(outcome?.best == MatchCandidate(track: pick, confidence: 100, reason: .manual))
        #expect(outcome?.alreadyInTarget == false)
    }

    @Test("A pick the other playlist already holds counts as there")
    func pinnedAlreadyInTarget() {
        let picked = row(spotify("s1", "Word Up!"))
        let pick = apple("ep", album: "Word Up!: The Remixes - EP")

        let split = PinnedPlanning.split([picked], pins: [picked.key: pick], targetPlaylists: [.appleMusic: [pick]])

        #expect(split.outcomes[picked.key]?.alreadyInTarget == true)
    }

    @Test("The plan adds a pick automatically, as the person's choice")
    func pickIsAnAutomaticAdd() {
        let picked = row(spotify("s1", "Word Up!"))
        let pick = apple("ep", album: "Word Up!: The Remixes - EP")
        let outcomes = PinnedPlanning.split([picked], pins: [picked.key: pick], targetPlaylists: [:]).outcomes

        let plan = PlanBuilder.build(PlanInput(
            pairId: UUID(), direction: .spotifyToApple, sourcePlatform: .spotify, removalPolicy: .keep,
            confidence: ConfidencePolicy(), rows: [picked], outcomes: outcomes, appleMusicCanRemove: false
        ))

        #expect(plan.side(.appleMusic).automaticAdds.map(\.match) == [MatchCandidate(track: pick, confidence: 100, reason: .manual)])
    }

    @Test("A seam keeps its picks by song")
    @MainActor
    func pinRoundTrip() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "s", spotifyPlaylistName: "Remixes", appleMusicPlaylistId: "a",
                            appleMusicPlaylistName: "Remixes", syncDirection: .spotifyToApple)
        context.insert(pair)
        let key = TrackKey(spotify("s1", "Word Up!"))
        let pick = apple("ep", album: "Word Up!: The Remixes - EP")
        let pin = PinnedMatch(key: key, track: pick)
        pin.syncPair = pair
        context.insert(pin)
        try context.save()

        #expect(pair.pinnedTracks == [key: pick])
    }

    @Test("Unlinking a seam forgets its picks")
    func unlinkRemovesPins() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "s", spotifyPlaylistName: "Remixes", appleMusicPlaylistId: "a",
                            appleMusicPlaylistName: "Remixes", syncDirection: .spotifyToApple)
        context.insert(pair)
        let pin = PinnedMatch(key: TrackKey(spotify("s1", "Word Up!")), track: apple("ep", album: "Word Up!: The Remixes - EP"))
        pin.syncPair = pair
        context.insert(pin)
        try context.save()

        try await SwiftDataSeamRepository(modelContainer: container).unlink(pair.id)

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PinnedMatch>()) == 0)
    }

    @Test("History says a pick was the person's")
    func pickRunCopy() {
        let run = RunRecord(id: UUID(), seamId: UUID(), seamName: "Remixes", direction: .spotifyToApple, date: .now,
                            trigger: .pick, result: .success, duration: nil, failed: 0, undoneAt: nil, undoOfRunId: nil, changes: [])
        #expect(ActivityCopy.started(run) == "Your pick")
    }
}
