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
    func choose(_ candidate: MatchCandidate, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func keepPick(_ track: CatalogTrack, for key: TrackKey, seamId: UUID) async throws {}
    func forgetPick(for key: TrackKey, seamId: UUID) async throws {}
}

@Suite("Sync flow")
@MainActor
struct SyncFlowModelTests {

    private func plan(adds: Int = 0, conflicts: Int = 0, reorders: Platform? = nil) -> PlannedSync {
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
        var p = SyncPlan(pairId: id, createdAt: .now, sides: [.appleMusic: apple], conflicts: removed, inSyncCount: 0)
        p.reorders = reorders
        return PlannedSync(plan: p, fingerprint: PlaylistFingerprint(spotifyTracks: [], appleMusicTracks: []), sourcePlatform: .spotify)
    }

    private func model(_ planned: PlannedSync) async -> SyncFlowModel {
        let m = SyncFlowModel(seamId: planned.plan.pairId, isFirstSync: false, sync: FixedPlanService(planned: planned),
                              seams: PreviewSeamRepository(seams: []))
        await m.plan()
        return m
    }

    @Test("Reopened from the progress bar, the sheet follows the running sync instead of planning a new one")
    func followsRunning() async {
        let planned = plan(adds: 3, conflicts: 0)
        let m = SyncFlowModel(seamId: planned.plan.pairId, isFirstSync: false, sync: FixedPlanService(planned: planned),
                              seams: PreviewSeamRepository(seams: []))
        m.followRunningSync()
        guard case .syncing = m.phase else { Issue.record("expected the live sheet, got \(m.phase)"); return }
        #expect(m.afterApply == .showResult, "it ends on the result screen")
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

    @Test("Only the order changed: the button says so, applying reorders and closes")
    func reorderOnly() async {
        let m = await model(plan(reorders: .appleMusic))
        #expect(m.primaryTitle == "Reorder Apple Music")
        #expect(m.afterApply == .dismiss)
    }

    @Test("Removals waiting for a decision are listed with every track")
    func everyTrackListsConflicts() async {
        let m = await model(plan(conflicts: 2))
        #expect(m.conflictTitles == ["Holocene", "Holocene"])
    }

    @Test("Picking a version in the preview changes the plan in place, as the person's pick")
    func chooseInPreview() async throws {
        let m = await model(plan(adds: 3))
        let adds = { m.planned?.plan.side(.appleMusic).automaticAdds ?? [] }
        let source = try #require(adds().dropFirst().first?.source)
        let pick = CatalogTrack(platform: .appleMusic, id: "picked", title: "Track 1", artist: "A", album: "The Remixes - EP")

        try await m.choose(MatchCandidate(track: pick, confidence: 80, reason: .titleArtistDuration), for: source)

        #expect(adds().map(\.match.track.id) == ["s0", "picked", "s2"])
        #expect(adds()[1].match.reason == .manual)
        #expect(m.writeCount == 3, "still three tracks to write")
    }

    @Test("Only a running sync or an unacknowledged result survive being hidden")
    func keepsStateWhileHidden() async {
        let m = await model(plan(adds: 1))
        #expect(!m.keepsStateWhileHidden, "still just a preview: nothing to keep")
        m.debugStart()
        #expect(m.keepsStateWhileHidden, "running: reopening should show the same progress")
        m.debugFinish(SyncResult(pairId: m.seamId, status: .success, tracksAdded: 1))
        #expect(m.keepsStateWhileHidden, "done: reopening should show the same result")
    }

    @Test("Reopened while still running: reconciling leaves it alone")
    func reconcileStillRunning() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let coordinator = SyncCoordinator(modelContainer: container)
        let m = await model(plan(adds: 2))
        m.debugStart()
        coordinator.simulateRunning(pairId: m.seamId, progress: SyncProgress(totalTracks: 2, completedTracks: 1, failedTracks: 0))

        await m.reconcile(with: coordinator)

        guard case .syncing = m.phase else { Issue.record("expected it to still be syncing, got \(m.phase)"); return }
    }

    @Test("Finished while hidden: reopening catches up to the real result instead of staying stuck")
    func reconcileCatchesUpToResult() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let coordinator = SyncCoordinator(modelContainer: container)
        let m = await model(plan(adds: 2))
        m.debugStart()
        // Nothing simulates it running; `cancelSync` is a convenient way to
        // give the coordinator a finished result for this pair without one.
        coordinator.cancelSync(pairId: m.seamId)

        let caughtUp = await m.reconcile(with: coordinator)

        guard case .done(let result) = m.phase else { Issue.record("expected the real result, got \(m.phase)"); return }
        #expect(result.status == .failed)
        #expect(caughtUp, "the caller then does what the live sheet would have (open removal questions)")
    }

    @Test("A flow that's only following a running sync still gets the seam's name and covers")
    func loadSeamIfNeededFillsInAFollowedFlow() async {
        let seam = PreviewFixtures.lateNightDrive
        let m = SyncFlowModel(seamId: seam.id, isFirstSync: false, sync: PreviewSyncService(),
                              seams: PreviewSeamRepository(seams: [seam]))
        m.followRunningSync()
        #expect(m.seam == nil, "not loaded yet: this is the gap the fix closes")

        await m.loadSeamIfNeeded()

        #expect(m.seam?.id == seam.id)
    }

    @Test("The live sheet shows as many rows as fit, around the track being added")
    func landingWindow() {
        // Four fit (half height): two added, the current one, one waiting.
        #expect(SyncingView.window(done: 10, count: 35, fits: 4) == 8..<12)
        // The sheet expanded: more rows, still centered on the current one.
        #expect(SyncingView.window(done: 10, count: 35, fits: 9) == 6..<15)
        // Edges: the first rows at the start, the last rows at the end.
        #expect(SyncingView.window(done: 0, count: 35, fits: 4) == 0..<4)
        #expect(SyncingView.window(done: 35, count: 35, fits: 4) == 31..<35)
        // Fewer tracks than fit, or room for none.
        #expect(SyncingView.window(done: 1, count: 3, fits: 9) == 0..<3)
        #expect(SyncingView.window(done: 5, count: 35, fits: 0) == 5..<5)
    }

    @Test("Not syncing: reconciling a flow that hasn't started does nothing")
    func reconcileIgnoresUnstartedFlow() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let coordinator = SyncCoordinator(modelContainer: container)
        let m = await model(plan(adds: 1))

        await m.reconcile(with: coordinator)

        guard case .preview = m.phase else { Issue.record("expected it to stay in preview, got \(m.phase)"); return }
    }
}
