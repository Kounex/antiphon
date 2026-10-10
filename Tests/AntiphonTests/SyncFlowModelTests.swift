import Foundation
import Testing
@testable import Antiphon

/// Returns a fixed plan from `preview`.
struct FixedPlanService: SyncService {
    let planned: PlannedSync
    func preview(seamId: UUID, isFirstSync: Bool, progress: (@Sendable (Int, Int) async -> Void)?) async throws -> PlannedSync { planned }
    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger, progress: SyncProgressCallback?) async -> SyncResult {
        SyncResult(pairId: planned.plan.pairId, status: .success)
    }
    func undoPreview(runId: UUID) async throws -> UndoPlan { fatalError() }
    func undo(runId: UUID) async throws -> OperationRunner.Outcome { fatalError() }
    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome { fatalError() }
    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome { fatalError() }
}

@Suite("Sync flow")
@MainActor
struct SyncFlowModelTests {

    private func plan(adds: Int = 0, conflicts: Int = 0) -> PlannedSync {
        let id = UUID()
        var apple = SyncPlan.Side(platform: .appleMusic)
        apple.automaticAdds = (0..<adds).map { n in
            let t = CatalogTrack(platform: .spotify, id: "s\(n)", title: "Track \(n)", artist: "A")
            return SyncPlan.Add(source: t, match: MatchCandidate(track: t, confidence: 100, reason: .isrc), alternatives: [])
        }
        let removed = (0..<conflicts).map { n -> SyncPlan.Conflict in
            let t = CatalogTrack(platform: .spotify, id: "c\(n)", title: "Holocene", artist: "Bon Iver")
            return SyncPlan.Conflict(key: TrackKey(t), track: t, removedFrom: .appleMusic, noticedAt: nil)
        }
        let p = SyncPlan(pairId: id, createdAt: .now, sides: [.appleMusic: apple], conflicts: removed, inSyncCount: 0)
        return PlannedSync(plan: p, fingerprint: PlaylistFingerprint(spotifyTracks: [], appleMusicTracks: []), sourcePlatform: .spotify)
    }

    private func model(_ planned: PlannedSync) async -> SyncFlowModel {
        let m = SyncFlowModel(seamId: planned.plan.pairId, isFirstSync: false, sync: FixedPlanService(planned: planned),
                              seams: PreviewSeamRepository(seams: []))
        await m.plan()
        return m
    }

    @Test("Writes: sync them, then show the result")
    func writes() async {
        let m = await model(plan(adds: 3, conflicts: 1))
        #expect(m.primaryTitle == "Sync 3 tracks now")
        #expect(m.afterApply == .showResult)
    }

    @Test("Only a removal to decide: record it, then ask")
    func onlyConflicts() async {
        let m = await model(plan(conflicts: 1))
        #expect(m.primaryTitle == "Decide about 1 removal")
        #expect(m.afterApply == .openConflicts)
    }

    @Test("Nothing to do: record the check and close")
    func nothing() async {
        let m = await model(plan())
        #expect(m.primaryTitle == "Done")
        #expect(m.afterApply == .dismiss)
    }

    @Test("Removals waiting for a decision are listed with every track")
    func everyTrackListsConflicts() async {
        let m = await model(plan(conflicts: 2))
        #expect(m.conflictTitles == ["Holocene", "Holocene"])
    }
}
