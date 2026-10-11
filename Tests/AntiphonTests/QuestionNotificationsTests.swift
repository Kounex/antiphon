import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Antiphon

/// Records what an answered notification asked the sync service to do.
private final class RecordingSync: SyncService, Sendable {
    let calls = Mutex<[String]>([])

    func preview(seamId: UUID, isFirstSync: Bool, progress: (@Sendable (Int, Int) async -> Void)?) async throws -> PlannedSync {
        throw OperationRunner.Failure.pairNotFound
    }
    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger, progress: SyncProgressCallback?) async -> SyncResult {
        SyncResult(pairId: planned.plan.pairId, status: .success)
    }
    func undoPreview(runId: UUID) async throws -> UndoPlan { throw OperationRunner.Failure.runNotFound }
    func undo(runId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome {
        calls.withLock { $0 += resolutions.map { "resolve \($0.conflict.track.title) \($0.rowUpdate) \($0.operations.map { "\($0.kind) on \($0.platform.rawValue)" })" } }
        return OperationRunner.Outcome()
    }
    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome {
        let what = switch decision {
        case .accept(let candidate): "accept \(candidate.track.title)"
        case .skip: "skip"
        }
        calls.withLock { $0.append("\(what) for \(key.id)") }
        return OperationRunner.Outcome()
    }
}

@Suite("Question notifications", .serialized)
struct QuestionNotificationsTests {

    private func review(_ candidate: String, confidence: Int = 86) -> ReviewItem {
        ReviewItem(
            id: UUID(), seamId: UUID(), seamName: "Late Night Drive",
            key: TrackKey(platform: .spotify, id: "spotify:track:mc"),
            source: CatalogTrack(platform: .spotify, id: "spotify:track:mc", title: "Midnight City", artist: "M83"),
            candidates: [MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "c1", title: candidate, artist: "M83"),
                                        confidence: confidence, reason: .versionDifference)]
        )
    }

    private func conflict(removedFrom: Platform, appleMusicCanRemove: Bool) -> ConflictItem {
        let track = CatalogTrack(platform: .spotify, id: "spotify:track:holo", title: "Holocene", artist: "Bon Iver")
        return ConflictItem(seamId: UUID(), seamName: "Garden Sundays",
                            conflict: .init(key: TrackKey(track), track: track, removedFrom: removedFrom, noticedAt: nil),
                            remainingPlaylistName: "Garden Sundays", appleMusicCanRemove: appleMusicCanRemove, rowId: UUID())
    }

    // MARK: - Content

    @Test("A close match asks with the decision as its buttons")
    func closeMatch() throws {
        let item = review("Midnight City (Remaster)")
        let notice = QuestionNotice(item)
        #expect(notice.title == "Is this the same track?")
        #expect(notice.subtitle == "Late Night Drive")
        #expect(notice.body == "Midnight City by M83. Apple Music only has Midnight City (Remaster) (86% match).")
        #expect(notice.category == .closeMatchRemaster)
        #expect(notice.userInfo["seamId"] == item.seamId.uuidString)
        #expect(notice.userInfo["rowId"] == item.id.uuidString)
        #expect(QuestionNotice(review("Midnight City (Live)")).category == .closeMatch)
        #expect(notice.id == QuestionNotice.id(seamId: item.seamId, key: item.key))
    }

    @Test("Use remaster only when the offered version adds a remaster the original doesn't have")
    func remasterLabel() {
        var item = review("Midnight City (Remaster)")
        item = ReviewItem(id: item.id, seamId: item.seamId, seamName: item.seamName, key: item.key,
                          source: CatalogTrack(platform: .spotify, id: "spotify:track:mc", title: "Midnight City (2018 Remaster)", artist: "M83"),
                          candidates: item.candidates)
        #expect(QuestionNotice(item).category == .closeMatch)
    }

    @Test("A removal asks what to do with the copy that's left")
    func removal() {
        let notice = QuestionNotice(conflict(removedFrom: .appleMusic, appleMusicCanRemove: false))
        #expect(notice.title == "Holocene was removed on Apple Music")
        #expect(notice.body == "It's still in Garden Sundays on Spotify. Remove it there too?")
        #expect(notice.category == .removal)
        // Left on an Apple Music playlist Antiphon didn't make: it can't remove there (D1).
        #expect(QuestionNotice(conflict(removedFrom: .spotify, appleMusicCanRemove: false)).category == .removalKeepOrRestore)
        #expect(QuestionNotice(conflict(removedFrom: .spotify, appleMusicCanRemove: true)).category == .removal)
    }

    @Test("Each category's buttons, as the person sees them")
    func buttons() {
        #expect(QuestionCategory.closeMatch.actions.map(\.title) == ["Skip", "Use this version"])
        #expect(QuestionCategory.closeMatchRemaster.actions.map(\.title) == ["Skip", "Use remaster"])
        #expect(QuestionCategory.removal.actions.map(\.title) == ["Remove it too", "Put it back", "Leave as is"])
        #expect(QuestionCategory.removalKeepOrRestore.actions.map(\.title) == ["Put it back", "Leave as is"])
    }

    @Test("A removal's identity includes its seam, so the same track in two seams stays two questions")
    func conflictIdentity() {
        let a = conflict(removedFrom: .appleMusic, appleMusicCanRemove: true)
        let b = conflict(removedFrom: .appleMusic, appleMusicCanRemove: true)
        #expect(a.conflict.key == b.conflict.key)
        #expect(QuestionNotice(a).id != QuestionNotice(b).id)
        #expect(QuestionNotifications.identity(a) != QuestionNotifications.identity(b))
    }

    @Test("Up to three new questions get their own notifications; more get the summary")
    func howMany() {
        let three = QuestionNotifications.notices(review: [review("A (Remaster)"), review("B (Live)")],
                                                  conflicts: [conflict(removedFrom: .appleMusic, appleMusicCanRemove: true)])
        #expect(three.count == 3)
        let four = QuestionNotifications.notices(review: (0..<4).map { _ in review("A (Remaster)") }, conflicts: [])
        #expect(four.isEmpty)
    }

    // MARK: - Answers

    /// One close match in a one-way seam, one removal in a two-way seam.
    private func store() async throws -> (ModelContainer, review: ReviewItem, conflict: ConflictItem) {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let late = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Late Night Drive", appleMusicPlaylistId: "am",
                            appleMusicPlaylistName: "Late Night Drive", syncDirection: .spotifyToApple)
        context.insert(late)
        let row = CachedTrack(isrc: "R", title: "Midnight City", artist: "M83", spotifyTrackUri: "spotify:track:mc",
                              source: .spotify, syncState: .needsReview)
        row.candidates = [MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "c1", title: "Midnight City (Remaster)", artist: "M83"),
                                         confidence: 86, reason: .versionDifference)]
        row.syncPair = late
        context.insert(row)
        let garden = SyncPair(spotifyPlaylistId: "sp2", spotifyPlaylistName: "Garden Sundays", appleMusicPlaylistId: "am2",
                              appleMusicPlaylistName: "Garden Sundays", syncDirection: .bidirectional)
        garden.appleMusicCreatedByAntiphon = true
        context.insert(garden)
        let holocene = CachedTrack(isrc: "H", title: "Holocene", artist: "Bon Iver", spotifyTrackUri: "spotify:track:holo",
                                   appleMusicTrackId: "i.holo", source: .spotify, syncState: .synced)
        holocene.removalFlag = .removedFromAppleMusic
        holocene.removalFlaggedAt = Date()
        holocene.syncPair = garden
        context.insert(holocene)
        try context.save()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let item = try #require(try await repository.reviewItems(seamId: nil).first)
        let removal = try #require(try await repository.conflicts(seamId: nil).first)
        return (container, item, removal)
    }

    @Test("Buttons run the same decisions as the Review screen")
    func answers() async throws {
        let (container, item, removal) = try await store()
        let repository = SwiftDataSeamRepository(modelContainer: container)

        for (action, expected) in [(QuestionAction.useMatch, "accept Midnight City (Remaster) for spotify:track:mc"),
                                   (.skip, "skip for spotify:track:mc")] {
            let sync = RecordingSync()
            let answered = await QuestionNotifications.answer(action, userInfo: QuestionNotice(item).userInfo, review: repository, sync: sync)
            #expect(answered == .answered)
            #expect(sync.calls.withLock { $0 } == [expected])
        }

        for (action, expected) in [(QuestionAction.removeToo, "resolve Holocene forget [\"remove on Spotify\"]"),
                                   (.putBack, "resolve Holocene restore [\"add on Apple Music\"]"),
                                   (.leaveAsIs, "resolve Holocene keepDifference []")] {
            let sync = RecordingSync()
            _ = await QuestionNotifications.answer(action, userInfo: QuestionNotice(removal).userInfo, review: repository, sync: sync)
            #expect(sync.calls.withLock { $0 } == [expected])
        }
    }

    @Test("A question already answered in the app does nothing")
    func alreadyAnswered() async throws {
        let (container, item, _) = try await store()
        var info = QuestionNotice(item).userInfo
        info["rowId"] = UUID().uuidString
        let sync = RecordingSync()
        let answered = await QuestionNotifications.answer(.useMatch, userInfo: info,
                                                          review: SwiftDataSeamRepository(modelContainer: container), sync: sync)
        #expect(answered == .gone, "not a failure: nothing to tell the person")
        #expect(sync.calls.withLock { $0 }.isEmpty)
    }
}
