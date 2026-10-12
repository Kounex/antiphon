import Foundation
import Testing
@testable import Antiphon

@Suite("Live Activity")
struct SyncActivityTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The result shows for a few seconds before the activity ends (iOS removes ended ones from the Dynamic Island at once)")
    func resultShown() {
        #expect(SyncActivityPolicy.resultShownFor == 4)
    }

    @Test("Without an update for 30 seconds (iOS paused the app) it shows as paused, not as still working")
    func stale() {
        #expect(SyncActivityPolicy.staleDate(now: start) == start.addingTimeInterval(30))
        #expect(SyncActivityPolicy.pausedText == "Paused · open Antiphon to finish")
    }

    @Test("Time left, once a few tracks have gone through")
    func timeLeft() {
        #expect(SyncActivityContent.timeLeft(done: 2, total: 35, elapsed: 4) == nil, "too early to say")
        #expect(SyncActivityContent.timeLeft(done: 10, total: 35, elapsed: 20) == "about 1 min left")
        #expect(SyncActivityContent.timeLeft(done: 10, total: 70, elapsed: 30) == "about 3 min left")
        #expect(SyncActivityContent.timeLeft(done: 30, total: 35, elapsed: 30) == "a few seconds left")
    }

    @Test("The direction line under the bar")
    func direction() {
        #expect(SyncActivityContent.direction(.spotifyToApple) == "Spotify → Apple Music")
        #expect(SyncActivityContent.direction(.bidirectional) == "Spotify ↔ Apple Music")
    }

    @Test("Only syncs that run longer than 20 seconds get a Live Activity")
    func startsAfter20Seconds() {
        #expect(!SyncActivityPolicy.shouldStart(startedAt: start, now: start.addingTimeInterval(19)))
        #expect(SyncActivityPolicy.shouldStart(startedAt: start, now: start.addingTimeInterval(20)))
    }

    @Test("Updates at most every 2 seconds, but a new phase or seam shows at once")
    func throttle() {
        let state = SyncActivityAttributes.ContentState(seamName: "Workout Mix 2026", phase: "Adding to Apple Music", done: 20, total: 35)
        var later = state
        later.done = 21
        #expect(!SyncActivityPolicy.shouldUpdate(from: state, to: later, lastUpdate: start, now: start.addingTimeInterval(1)))
        #expect(SyncActivityPolicy.shouldUpdate(from: state, to: later, lastUpdate: start, now: start.addingTimeInterval(2)))
        var otherPhase = state
        otherPhase.phase = "Checking tracks"
        #expect(SyncActivityPolicy.shouldUpdate(from: state, to: otherPhase, lastUpdate: start, now: start.addingTimeInterval(0.5)))
        #expect(!SyncActivityPolicy.shouldUpdate(from: state, to: state, lastUpdate: start, now: start.addingTimeInterval(10)))
    }

    @Test("What the Live Activity says, from the sync's progress (board 9: Adding to Apple Music, 20 of 35)")
    func content() {
        let adding = SyncActivityContent.state(seamName: "Workout Mix 2026",
                                               progress: SyncProgress(totalTracks: 35, completedTracks: 19, failedTracks: 1,
                                                                      phase: .adding(platformName: "Apple Music")))
        #expect(adding == .init(seamName: "Workout Mix 2026", phase: "Adding to Apple Music", done: 20, total: 35))
        let checking = SyncActivityContent.state(seamName: "Run Club", progress: SyncProgress(totalTracks: 52, completedTracks: 30, failedTracks: 0))
        #expect(checking.phase == "Checking tracks")
        #expect(SyncActivityContent.count(adding) == ("20", "of 35"))
    }

    @Test("Sync all leaves first syncs, paused seams and rebuilds to the person")
    func syncAllScope() {
        func seam(checked: Bool = true, paused: Bool = false, rebuild: Bool = false) -> SeamSummary {
            SeamSummary(id: UUID(), spotify: SeamSide(platform: .spotify, playlistId: "s", name: "A", artworkURL: nil),
                        appleMusic: SeamSide(platform: .appleMusic, playlistId: "a", name: "A", artworkURL: nil),
                        direction: .spotifyToApple, isMonitored: false, isPaused: paused, monitorIntervalMinutes: 15,
                        lastCheckedAt: checked ? start : nil, lastResult: nil,
                        counts: SeamCounts(synced: 0, review: 0, missing: 0, total: 0), needsRebuild: rebuild)
        }
        #expect(SyncAllScope.waiting([seam(), seam(checked: false), seam(paused: true), seam(rebuild: true)]) == 3)
        #expect(SyncAllScope.waiting([seam(), seam()]) == 0)
    }

    @Test("How it ends")
    func ending() {
        #expect(SyncActivityContent.finished(seamName: "Workout Mix 2026", result: SyncResult(pairId: UUID(), status: .success, tracksAdded: 35))
                == .init(seamName: "Workout Mix 2026", phase: "Synced · 35 added", done: 1, total: 1, finished: true))
        let failed = SyncActivityContent.finished(seamName: "Run Club", result: SyncResult(pairId: UUID(), status: .failed))
        #expect(failed.phase == "Didn't finish. Open Antiphon to see why.")
        #expect(failed.failed, "the Dynamic Island says Stopped, not Done")
        // Partial covers pauses, stale previews and tracks left for next time: say so, no more.
        #expect(SyncActivityContent.finished(seamName: "Run Club", result: SyncResult(pairId: UUID(), status: .partial, tracksAdded: 2)).phase
                == "2 added · not everything is done. Open Antiphon to see what's left.")
        #expect(SyncActivityContent.finished(seamName: "Run Club", result: SyncResult(pairId: UUID(), status: .success)).phase
                == "In sync")
        let all = SyncActivityContent.finishedAll([SyncResult(pairId: UUID(), status: .success, tracksAdded: 3),
                                                   SyncResult(pairId: UUID(), status: .partial, tracksAdded: 2),
                                                   SyncResult(pairId: UUID(), status: .failed)])
        #expect(all.seamName == "Sync all")
        #expect(all.phase == "1 of 3 seams fully synced · 5 added. Open Antiphon to see what's left.")
        #expect(SyncActivityContent.finishedAll([SyncResult(pairId: UUID(), status: .success)]).phase == "1 of 1 seam fully synced · 0 added")
        // Seams Sync all leaves to the person are said, not skipped quietly.
        #expect(SyncActivityContent.finishedAll([SyncResult(pairId: UUID(), status: .success)], waiting: 2).phase
                == "1 of 1 seam fully synced · 0 added · 2 wait for you in Antiphon")
        #expect(SyncActivityContent.finishedAll([], waiting: 3).phase == "Nothing to sync yet · 3 seams wait for you in Antiphon")
    }
}

@Suite("Continued sync")
struct ContinuedSyncTests {
    @Test("A sync the person started keeps running in the background under its own task identifier")
    func identifier() {
        let run = UUID()
        #expect(ContinuedSyncCopy.identifier(bundleID: "com.kounex.antiphon.dev", run: run)
                == "com.kounex.antiphon.dev.sync.\(run.uuidString)")
    }

    @Test("What iOS shows for it: the seam, what's happening and the count (its ring shows progress; one line has no room for time left)")
    func copy() {
        #expect(ContinuedSyncCopy.title(seamName: "edamame") == "Syncing edamame")
        let state = SyncActivityAttributes.ContentState(seamName: "edamame", phase: "Adding to Apple Music", done: 20, total: 35,
                                                        direction: "Spotify → Apple Music", timeLeft: "about 1 min left")
        #expect(ContinuedSyncCopy.subtitle(state) == "Adding to Apple Music · 20 of 35")
        #expect(ContinuedSyncCopy.subtitle(.init(seamName: "edamame", phase: "Checking tracks", done: 0, total: 0)) == "Checking tracks")
    }

    @Test("Progress only moves forward over the whole sync, and reaches the end only when it's done")
    func units() {
        func state(_ phase: String, _ done: Int, _ total: Int) -> SyncActivityAttributes.ContentState {
            .init(seamName: "edamame", phase: phase, done: done, total: total)
        }
        #expect(ContinuedSyncCopy.completedUnits(state("Checking tracks", 0, 25)) == 0)
        #expect(ContinuedSyncCopy.completedUnits(state("Checking tracks", 25, 25)) == 300, "checking is the first 30%")
        #expect(ContinuedSyncCopy.completedUnits(state("Adding to Apple Music", 0, 25)) == 300, "adding starts where checking ended")
        #expect(ContinuedSyncCopy.completedUnits(state("Adding to Apple Music", 25, 25)) == 990, "100% only when the sync ends")
        #expect(ContinuedSyncCopy.completedUnits(state("Adding to Spotify", 10, 20)) == 645)
    }
}
