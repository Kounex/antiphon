import Foundation
import Testing
@testable import Antiphon

@Suite("Plan builder")
struct PlanBuilderTests {

    // MARK: - Fixtures

    private func track(_ n: Int, on platform: Platform) -> CatalogTrack {
        CatalogTrack(
            platform: platform,
            id: platform == .spotify ? "spotify:track:\(n)" : "i.\(n)",
            title: "Track \(n)", artist: "Artist \(n)"
        )
    }

    private func row(
        _ n: Int,
        from platform: Platform,
        state: TrackSyncState = .pending,
        flag: RemovalFlag? = nil,
        kept: Bool = false,
        retries: Int = 0
    ) -> PlanRow {
        PlanRow(
            source: track(n, on: platform),
            counterpartId: state == .synced ? track(n, on: platform.other).id : nil,
            state: state,
            removalFlag: flag,
            removalKept: kept,
            retryCount: retries
        )
    }

    private func outcome(_ n: Int, on platform: Platform, confidence: Int, alreadyThere: Bool = false) -> MatchOutcome {
        MatchOutcome(
            best: MatchCandidate(track: track(n, on: platform), confidence: confidence, reason: confidence == 100 ? .isrc : .versionDifference),
            alternatives: [],
            alreadyInTarget: alreadyThere
        )
    }

    private func input(
        direction: SyncDirection,
        rows: [PlanRow],
        outcomes: [TrackKey: MatchOutcome] = [:],
        removalPolicy: RemovalPolicy? = nil,
        threshold: Int = 90,
        appleMusicCanRemove: Bool = false
    ) -> PlanInput {
        PlanInput(
            pairId: UUID(),
            direction: direction,
            sourcePlatform: direction == .appleToSpotify ? .appleMusic : .spotify,
            removalPolicy: removalPolicy ?? (direction == .bidirectional ? .ask : .keep),
            confidence: ConfidencePolicy(autoAddThreshold: threshold),
            rows: rows,
            outcomes: outcomes,
            appleMusicCanRemove: appleMusicCanRemove
        )
    }

    // MARK: - Preview counts

    /// The storyboard's first-sync preview: Workout Mix 2026 (Spotify) ↔ Gym Rotation (Apple Music).
    @Test("Storyboard first sync: +33 on Apple Music, +6 on Spotify, 35 to sync now")
    func storyboardPreview() {
        var rows: [PlanRow] = []
        var outcomes: [TrackKey: MatchOutcome] = [:]
        for n in 1...31 { rows.append(row(n, from: .spotify, state: .synced)) }          // on both
        for n in 100..<129 {                                                              // 29 exact
            rows.append(row(n, from: .spotify))
            outcomes[TrackKey(track(n, on: .spotify))] = outcome(n, on: .appleMusic, confidence: 100)
        }
        for n in 200..<203 {                                                              // 3 close
            rows.append(row(n, from: .spotify))
            outcomes[TrackKey(track(n, on: .spotify))] = outcome(n, on: .appleMusic, confidence: 84)
        }
        rows.append(row(300, from: .spotify))                                             // 1 unavailable
        outcomes[TrackKey(track(300, on: .spotify))] = MatchOutcome(best: nil, alternatives: [], alreadyInTarget: false)
        for n in 400..<406 {                                                              // 6 from Apple Music
            rows.append(row(n, from: .appleMusic))
            outcomes[TrackKey(track(n, on: .appleMusic))] = outcome(n, on: .spotify, confidence: 100)
        }

        let plan = PlanBuilder.build(input(direction: .bidirectional, rows: rows, outcomes: outcomes))

        let apple = plan.side(.appleMusic)
        #expect(apple.missingCount == 33)
        #expect(apple.automaticAdds.count == 29)
        #expect(apple.reviewAdds.count == 3)
        #expect(apple.unavailable.count == 1)

        let spotify = plan.side(.spotify)
        #expect(spotify.missingCount == 6)
        #expect(spotify.automaticAdds.count == 6)

        #expect(plan.totalMissing == 39)
        #expect(plan.automaticAddCount == 35)
        #expect(plan.removalCount == 0)
        #expect(plan.inSyncCount == 31)
    }

    @Test("One-way seams never plan anything for the source side")
    func oneWayIgnoresTargetOnlyTracks() {
        let rows = [
            row(1, from: .spotify),
            row(2, from: .appleMusic, state: .synced, flag: .extraOnDestination)
        ]
        let outcomes = [TrackKey(track(1, on: .spotify)): outcome(1, on: .appleMusic, confidence: 100)]
        let plan = PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, outcomes: outcomes))
        #expect(plan.side(.appleMusic).automaticAdds.count == 1)
        #expect(plan.side(.spotify).missingCount == 0)
    }

    @Test("A track already in the target playlist isn't added again")
    func alreadyInTarget() {
        let rows = [row(1, from: .spotify)]
        let outcomes = [TrackKey(track(1, on: .spotify)): outcome(1, on: .appleMusic, confidence: 100, alreadyThere: true)]
        let plan = PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, outcomes: outcomes))
        #expect(plan.side(.appleMusic).missingCount == 0)
        #expect(plan.automaticAddCount == 0)
    }

    @Test("A lower threshold moves close matches into automatic adds")
    func thresholdChangesCounts() {
        let rows = [row(1, from: .spotify)]
        let outcomes = [TrackKey(track(1, on: .spotify)): outcome(1, on: .appleMusic, confidence: 84)]
        #expect(PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, outcomes: outcomes)).automaticAddCount == 0)
        #expect(PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, outcomes: outcomes, threshold: 80)).automaticAddCount == 1)
    }

    @Test("Failed tracks are retried until their third attempt")
    func retryLimit() {
        let rows = [
            row(1, from: .spotify, state: .failed, retries: 2),
            row(2, from: .spotify, state: .failed, retries: 3)
        ]
        let outcomes = [
            TrackKey(track(1, on: .spotify)): outcome(1, on: .appleMusic, confidence: 100),
            TrackKey(track(2, on: .spotify)): outcome(2, on: .appleMusic, confidence: 100)
        ]
        let plan = PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, outcomes: outcomes))
        #expect(plan.side(.appleMusic).automaticAdds.map(\.source.id) == ["spotify:track:1"])
    }

    // MARK: - Removals

    @Test("By default nothing is removed: a one-way source removal is kept")
    func oneWayKeepsRemovals() {
        let rows = [row(1, from: .spotify, state: .synced, flag: .removedFromSource)]
        let plan = PlanBuilder.build(input(direction: .spotifyToApple, rows: rows))
        #expect(plan.removalCount == 0)
        #expect(plan.conflicts.isEmpty)
    }

    @Test("Mirror removals on Spotify are planned as removals")
    func mirrorRemovesOnSpotify() throws {
        let rows = [row(1, from: .appleMusic, state: .synced, flag: .removedFromSource)]
        let plan = PlanBuilder.build(input(direction: .appleToSpotify, rows: rows, removalPolicy: .mirror))
        let removal = try #require(plan.side(.spotify).removals.first)
        #expect(removal.track.id == "spotify:track:1")
        #expect(removal.isGuided == false)
    }

    @Test("Mirror removals on Apple Music are guided until Apple Music can remove")
    func mirrorOnAppleMusicIsGuided() {
        let rows = [row(1, from: .spotify, state: .synced, flag: .removedFromSource)]
        let guided = PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, removalPolicy: .mirror))
        #expect(guided.side(.appleMusic).removals.first?.isGuided == true)
        #expect(guided.removalCount == 0, "guided removals aren't counted as writes")

        let direct = PlanBuilder.build(input(direction: .spotifyToApple, rows: rows, removalPolicy: .mirror, appleMusicCanRemove: true))
        #expect(direct.side(.appleMusic).removals.first?.isGuided == false)
        #expect(direct.removalCount == 1)
    }

    @Test("In a two-way seam a removal becomes a conflict question")
    func twoWayRemovalIsConflict() {
        let rows = [
            row(1, from: .spotify, state: .synced, flag: .removedFromAppleMusic),
            row(2, from: .spotify, state: .synced, flag: .removedFromSource)
        ]
        let plan = PlanBuilder.build(input(direction: .bidirectional, rows: rows))
        #expect(plan.removalCount == 0)
        #expect(plan.conflicts.count == 2)
        #expect(plan.conflicts.first { $0.track.id == "spotify:track:1" }?.removedFrom == .appleMusic)
        #expect(plan.conflicts.first { $0.track.id == "spotify:track:2" }?.removedFrom == .spotify)
    }

    @Test("A removal the person already chose to keep is never asked about again")
    func keptRemovalIsQuiet() {
        let rows = [row(1, from: .spotify, state: .synced, flag: .removedFromAppleMusic, kept: true)]
        let plan = PlanBuilder.build(input(direction: .bidirectional, rows: rows))
        #expect(plan.conflicts.isEmpty)
    }
}

@Suite("Plan decisions")
struct PlanDecisionTests {
    private func t(_ n: Int, _ p: Platform) -> CatalogTrack {
        CatalogTrack(platform: p, id: "\(p)-\(n)", title: "T\(n)", artist: "A")
    }

    private func plan() -> SyncPlan {
        var apple = SyncPlan.Side(platform: .appleMusic)
        let auto = MatchCandidate(track: t(1, .appleMusic), confidence: 100, reason: .isrc)
        let close = MatchCandidate(track: t(2, .appleMusic), confidence: 84, reason: .versionDifference)
        let present = MatchCandidate(track: t(4, .appleMusic), confidence: 100, reason: .isrc)
        apple.automaticAdds = [.init(source: t(1, .spotify), match: auto, alternatives: [])]
        apple.reviewAdds = [.init(source: t(2, .spotify), match: close, alternatives: [])]
        apple.unavailable = [.init(source: t(3, .spotify), alternatives: [])]
        apple.alreadyPresent = [.init(source: t(4, .spotify), match: present, alternatives: [])]
        return SyncPlan(pairId: UUID(), createdAt: .now, sides: [.appleMusic: apple], conflicts: [], inSyncCount: 1)
    }

    @Test("Each planned track gets the decision its band calls for")
    func decisionsByBand() {
        let decisions = plan().decisions()
        #expect(decisions[TrackKey(t(1, .spotify))]?.writesTrack == true)
        #expect(decisions[TrackKey(t(2, .spotify))] == .review(MatchCandidate(track: t(2, .appleMusic), confidence: 84, reason: .versionDifference), alternatives: []))
        #expect(decisions[TrackKey(t(3, .spotify))] == .unavailable(alternatives: []))
        #expect(decisions[TrackKey(t(4, .spotify))] == .alreadyPresent(MatchCandidate(track: t(4, .appleMusic), confidence: 100, reason: .isrc)))
    }

    @Test("Approving a close match turns it into an add")
    func approvedReview() {
        let decisions = plan().decisions(approving: [TrackKey(t(2, .spotify))])
        #expect(decisions[TrackKey(t(2, .spotify))]?.writesTrack == true)
    }
}
