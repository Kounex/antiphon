import Foundation
import Testing
@testable import Antiphon

@Suite("Checks when the app opens")
struct OpenCheckTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seam(watched: Bool = true, paused: Bool = false, syncedMinutesAgo: Double? = 60,
                      rebuild: Bool = false, lookedMinutesAgo: Double? = nil) -> OpenCheck.Seam {
        OpenCheck.Seam(
            id: UUID(), isMonitored: watched, isPaused: paused,
            lastSyncedAt: syncedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, needsRebuild: rebuild,
            checkedAt: lookedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
        )
    }

    @Test("Watched seams sync whatever their interval; unwatched ones are only looked at")
    func whichSeams() {
        let watched = seam(syncedMinutesAgo: 6)
        let unwatched = seam(watched: false, syncedMinutesAgo: 600)
        let plan = OpenCheck.plan([watched, unwatched], now: now)
        #expect(plan.sync == [watched.id])
        #expect(plan.look == [unwatched.id])
    }

    @Test("Nothing again within five minutes, so switching apps doesn't recheck everything")
    func cooldown() {
        let justSynced = seam(syncedMinutesAgo: 2)
        let justLooked = seam(watched: false, syncedMinutesAgo: 600, lookedMinutesAgo: 1)
        let lookedLongAgo = seam(watched: false, syncedMinutesAgo: 600, lookedMinutesAgo: 30)
        let plan = OpenCheck.plan([justSynced, justLooked, lookedLongAgo], now: now)
        #expect(plan.sync.isEmpty)
        #expect(plan.look == [lookedLongAgo.id])
    }

    @Test("Paused seams, first syncs and rebuilds wait for the person")
    func leftAlone() {
        let plan = OpenCheck.plan([
            seam(paused: true), seam(watched: false, paused: true),
            seam(syncedMinutesAgo: nil), seam(watched: false, syncedMinutesAgo: nil),
            seam(rebuild: true), seam(watched: false, rebuild: true)
        ], now: now)
        #expect(plan.sync.isEmpty)
        #expect(plan.look.isEmpty)
    }

    // MARK: - Waiting changes

    private func row(_ n: Int, from platform: Platform, state: TrackSyncState = .pending,
                     flag: RemovalFlag? = nil, flaggedAt: Date? = nil) -> PlanRow {
        let id = platform == .spotify ? "spotify:track:\(n)" : "i.\(n)"
        return PlanRow(
            source: CatalogTrack(platform: platform, id: id, title: "Track \(n)", artist: "Artist"),
            counterpartId: state == .synced ? (platform == .spotify ? "i.\(n)" : "spotify:track:\(n)") : nil,
            state: state, removalFlag: flag, removalKept: false, retryCount: 0, removalFlaggedAt: flaggedAt
        )
    }

    private func waiting(_ rows: [PlanRow], _ direction: SyncDirection, _ policy: RemovalPolicy) -> Int {
        OpenCheck.waiting(rows: rows, direction: direction, sourcePlatform: .spotify, policy: policy,
                          appleMusicCanRemove: true, since: now)
    }

    @Test("New tracks on the side the seam follows count; the target's own tracks and synced ones don't")
    func newTracks() {
        let rows = [row(1, from: .spotify), row(2, from: .spotify), row(3, from: .appleMusic),
                    row(4, from: .spotify, state: .synced), row(5, from: .spotify, state: .failed)]
        #expect(waiting(rows, .spotifyToApple, .keep) == 2)
        #expect(waiting(rows, .bidirectional, .keep) == 3)
    }

    @Test("Removals count when the seam would act on them")
    func removals() {
        let removed = row(1, from: .spotify, state: .synced, flag: .removedFromSpotify, flaggedAt: now)
        #expect(waiting([removed], .spotifyToApple, .mirror) == 1)
        #expect(waiting([removed], .spotifyToApple, .ask) == 1)
        #expect(waiting([removed], .spotifyToApple, .keep) == 0)
    }

    @Test("A question already waiting in Review isn't counted twice")
    func knownQuestions() {
        let asked = row(1, from: .spotify, state: .synced, flag: .removedFromSpotify, flaggedAt: now.addingTimeInterval(-3600))
        #expect(waiting([asked], .spotifyToApple, .ask) == 0)
    }
}
