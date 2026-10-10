import Foundation
import Testing
@testable import Antiphon

@Suite("Plan copy")
struct PlanCopyTests {

    private func plan(adds: [Platform: Int] = [:], review: Int = 0, removals: Int = 0, guided: Int = 0, conflicts: Int = 0) -> SyncPlan {
        func add(_ n: Int, _ p: Platform) -> SyncPlan.Add {
            let t = CatalogTrack(platform: p.other, id: "\(p)-\(n)", title: "T\(n)", artist: "A")
            return .init(source: t, match: .init(track: t, confidence: 100, reason: .isrc), alternatives: [])
        }
        var sides: [Platform: SyncPlan.Side] = [:]
        for p in Platform.allCases {
            var side = SyncPlan.Side(platform: p)
            side.automaticAdds = (0..<(adds[p] ?? 0)).map { add($0, p) }
            if p == .appleMusic {
                side.reviewAdds = (0..<review).map { add(100 + $0, p) }
                let t = CatalogTrack(platform: p, id: "r", title: "R", artist: "A")
                side.removals = Array(repeating: .init(track: t, isGuided: false), count: removals)
                    + Array(repeating: .init(track: t, isGuided: true), count: guided)
            }
            sides[p] = side
        }
        let t = CatalogTrack(platform: .spotify, id: "c", title: "C", artist: "A")
        let c = Array(repeating: SyncPlan.Conflict(key: TrackKey(t), track: t, removedFrom: .appleMusic, noticedAt: nil), count: conflicts)
        return SyncPlan(pairId: UUID(), createdAt: .now, sides: sides, conflicts: c, inSyncCount: 0)
    }

    @Test("Storyboard first sync states that nothing is removed, then what's added now")
    func storyboardHeadline() {
        let p = plan(adds: [.appleMusic: 29, .spotify: 6], review: 3)
        #expect(PlanCopy.headline(for: p) == "Nothing is removed. 35 tracks are added.")
    }

    @Test("Removals come first, because they're the worst case")
    func removalsFirst() {
        #expect(PlanCopy.headline(for: plan(adds: [.spotify: 1], removals: 2)) == "Removes 2 tracks. 1 track is added.")
    }

    @Test("Nothing to do says so")
    func nothingToDo() {
        #expect(PlanCopy.headline(for: plan()) == "Everything is already in sync.")
    }

    @Test("Only close matches: nothing is added until you decide")
    func onlyReview() {
        #expect(PlanCopy.headline(for: plan(review: 3)) == "Nothing is removed. Nothing is added until you review 3 close matches.")
    }

    @Test("Conflicts are mentioned when there are no writes")
    func onlyConflicts() {
        #expect(PlanCopy.headline(for: plan(conflicts: 1)) == "Nothing changes until you decide about 1 removed track.")
    }

    @Test("Per-side sentence names the playlist and platform")
    func sideSentence() {
        let p = plan(adds: [.appleMusic: 12])
        #expect(PlanCopy.sideSentence(for: p.side(.appleMusic), playlistName: "Late Night Drive")
                == "Adds 12 tracks to Late Night Drive on Apple Music. Removes nothing.")
        let r = plan(removals: 1)
        #expect(PlanCopy.sideSentence(for: r.side(.appleMusic), playlistName: "Garden Sundays")
                == "Adds nothing to Garden Sundays on Apple Music. Removes 1 track.")
    }
}

@Suite("Preview fixtures")
struct PreviewFixtureTests {
    @Test("The preview plan matches the storyboard's first sync")
    func firstSyncFixture() {
        let plan = PreviewFixtures.firstSyncPlan().plan
        #expect(plan.side(.appleMusic).missingCount == 33)
        #expect(plan.side(.spotify).missingCount == 6)
        #expect(plan.automaticAddCount == 35)
        #expect(PlanCopy.headline(for: plan) == "Nothing is removed. 35 tracks are added.")
    }
}
