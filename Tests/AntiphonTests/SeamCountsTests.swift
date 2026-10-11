import Foundation
import Testing
@testable import Antiphon

@Suite("Seam counts and track states")
struct SeamCountsTests {

    private func row(
        _ state: TrackSyncState,
        flag: RemovalFlag? = nil,
        kept: Bool = false,
        unmatched: UnmatchedPlatform? = nil,
        confidence: Int? = nil,
        reason: MatchReason? = nil
    ) -> CachedTrack {
        let track = CachedTrack(isrc: UUID().uuidString, title: "T", artist: "A", source: .spotify, syncState: state)
        track.removalFlag = flag
        track.removalKeptAt = kept ? Date() : nil
        track.unmatchedPlatform = unmatched
        track.matchConfidence = confidence
        track.matchReason = reason
        return track
    }

    @Test("Storyboard card: 48 of 52 in sync, 3 to review, 1 missing")
    func storyboardCard() {
        let tracks = Array(repeating: (), count: 48).map { row(.synced) }
            + Array(repeating: (), count: 3).map { row(.needsReview, confidence: 86) }
            + [row(.failed, unmatched: .appleMusic)]
        let counts = SeamCounts(tracks: tracks, direction: .spotifyToApple, policy: .keep)
        #expect(counts == SeamCounts(synced: 48, review: 3, missing: 1, total: 52))
        #expect(counts.accessibilityValue == "48 synced, 3 to review, 1 missing")
    }

    @Test("Two-way removals waiting for an answer count as review")
    func conflictsNeedReview() {
        let counts = SeamCounts(tracks: [row(.synced, flag: .removedFromAppleMusic), row(.synced)], direction: .bidirectional, policy: .ask)
        #expect(counts.review == 1)
        #expect(counts.synced == 1)
    }

    @Test("Kept differences and target-only tracks are left out entirely")
    func ignoredRowsExcluded() {
        let tracks = [
            row(.synced, flag: .removedFromAppleMusic, kept: true),
            row(.synced, flag: .extraOnDestination),
            row(.synced, flag: .removedFromSource),       // one-way, kept by policy
            row(.synced)
        ]
        let counts = SeamCounts(tracks: tracks, direction: .spotifyToApple, policy: .keep)
        #expect(counts == SeamCounts(synced: 1, review: 0, missing: 0, total: 1))
    }

    @Test("Pending tracks count toward the total only")
    func pendingInTotal() {
        let counts = SeamCounts(tracks: [row(.pending), row(.synced)], direction: .spotifyToApple, policy: .keep)
        #expect(counts == SeamCounts(synced: 1, review: 0, missing: 0, total: 2))
    }

    @Test("Keep and Mirror seams don't ask, so their removals aren't counted as review")
    func onlyAskCountsRemovals() {
        let tracks = [row(.synced, flag: .removedFromAppleMusic), row(.synced)]
        for policy in [RemovalPolicy.keep, .mirror] {
            #expect(SeamCounts(tracks: tracks, direction: .bidirectional, policy: policy)
                    == SeamCounts(synced: 1, review: 0, missing: 0, total: 1), "\(policy)")
        }
    }

    @Test("A one-way seam set to Ask counts its source removals as review")
    func oneWayAskCountsSourceRemovals() {
        let counts = SeamCounts(tracks: [row(.synced, flag: .removedFromSource), row(.synced)],
                                direction: .spotifyToApple, policy: .ask)
        #expect(counts.review == 1)
    }

    // MARK: - Run status

    @Test("A track the other catalog doesn't have makes a run partial, not failed")
    func missingIsPartial() {
        #expect(SyncResultStatus.after([row(.synced), row(.failed, unmatched: .appleMusic)]) == .partial)
    }

    @Test("A track that hit an error fails the run")
    func errorFails() {
        #expect(SyncResultStatus.after([row(.synced), row(.failed), row(.failed, unmatched: .spotify)]) == .failed)
    }

    @Test("Removal flags make a run partial; everything in sync is a success")
    func flagsAndSuccess() {
        #expect(SyncResultStatus.after([row(.synced), row(.synced, flag: .removedFromSource)]) == .partial)
        #expect(SyncResultStatus.after([row(.synced), row(.skipped)]) == .success)
    }

    @Test("Close matches waiting in Review make a run partial, not a success")
    func reviewIsPartial() {
        #expect(SyncResultStatus.after([row(.synced), row(.needsReview, confidence: 80)]) == .partial)
    }

    // MARK: - Track row states

    @Test("Row states map to what the track row shows")
    func rowStates() {
        #expect(TrackRowState(row(.synced)) == .synced)
        #expect(TrackRowState(row(.syncing)) == .syncing)
        #expect(TrackRowState(row(.needsReview, confidence: 86, reason: .versionDifference)) == .review(confidence: 86, reason: .versionDifference))
        #expect(TrackRowState(row(.pending)) == .pending)
    }

    @Test("Unavailable tracks say where they're missing, and why")
    func missingReasons() {
        let regionLocked = row(.failed, unmatched: .appleMusic)
        regionLocked.unavailableReason = .regionLocked
        regionLocked.unavailableStorefront = "DE"
        #expect(TrackRowState(regionLocked) == .missing("Not on Apple Music in Germany"))

        let notInCatalog = row(.failed, unmatched: .spotify)
        #expect(TrackRowState(notInCatalog) == .missing("Not on Spotify"))
    }

    @Test("A failure that isn't about availability shows as failed")
    func failedState() {
        #expect(TrackRowState(row(.failed)) == .failed("Couldn't sync this track. Antiphon will try again."))
    }
}
