import Foundation
import Testing
@testable import Antiphon

@Suite("Skipping a check when nothing changed")
struct UnchangedCheckTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ state: TrackSyncState, appleId: String? = "i.1", flag: RemovalFlag? = nil,
                     retries: Int = 0, lastAttempt: Date? = nil) -> UnchangedCheck.Row {
        .init(state: state, appleMusicId: appleId, removalFlag: flag, retryCount: retries, lastAttempt: lastAttempt)
    }

    private func token(_ snapshot: String = "snap1", _ ids: [String] = ["i.1", "i.2"], rules: String = "r") -> String {
        UnchangedCheck.token(spotifySnapshot: snapshot, appleMusicIds: ids, rules: rules)
    }

    @Test("Same Spotify snapshot, same Apple Music tracks, same rules: nothing to do")
    func unchanged() {
        #expect(UnchangedCheck.canSkip(stored: token(), live: token(), rows: [row(.synced), row(.synced, appleId: "i.2")],
                                       liveAppleIds: ["i.1", "i.2"], recheck: .weekly, now: now))
    }

    @Test("Any difference means a full check: Spotify changed, Apple Music changed or reordered, rules changed")
    func changed() {
        let rows = [row(.synced)]
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token("snap2"), rows: rows, liveAppleIds: ["i.1"], recheck: .weekly, now: now))
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token("snap1", ["i.1"]), rows: rows, liveAppleIds: ["i.1"], recheck: .weekly, now: now))
        #expect(token("snap1", ["i.1", "i.2"]) != token("snap1", ["i.2", "i.1"]), "order counts")
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token(rules: "mirror"), rows: rows, liveAppleIds: ["i.1"], recheck: .weekly, now: now))
        #expect(!UnchangedCheck.canSkip(stored: nil, live: token(), rows: rows, liveAppleIds: ["i.1"], recheck: .weekly, now: now),
                "never settled: check in full")
    }

    @Test("Work that waits in the store isn't skipped, whatever the playlists say")
    func pendingWork() {
        let ids: Set<String> = ["i.1"]
        // Left over by a run that ran out of time.
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token(), rows: [row(.pending, appleId: nil)], liveAppleIds: ids, recheck: .weekly, now: now))
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token(), rows: [row(.syncing)], liveAppleIds: ids, recheck: .weekly, now: now))
        // Not found three times, and the weekly recheck is due.
        let due = row(.failed, appleId: nil, retries: 3, lastAttempt: now.addingTimeInterval(-8 * 86_400))
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token(), rows: [due], liveAppleIds: ids, recheck: .weekly, now: now))
        let notDue = row(.failed, appleId: nil, retries: 3, lastAttempt: now.addingTimeInterval(-2 * 86_400))
        #expect(UnchangedCheck.canSkip(stored: token(), live: token(), rows: [notDue], liveAppleIds: ids, recheck: .weekly, now: now))
        // A close match waiting for the person needs them, not a run.
        #expect(UnchangedCheck.canSkip(stored: token(), live: token(), rows: [row(.needsReview, appleId: nil)], liveAppleIds: ids, recheck: .weekly, now: now))
    }

    @Test("A song Antiphon added that Apple Music still doesn't list gets a full check (it may need adding again)")
    func neverArrived() {
        let stranded = row(.synced, appleId: "1831584253")
        #expect(!UnchangedCheck.canSkip(stored: token(), live: token(), rows: [stranded], liveAppleIds: ["i.1"], recheck: .weekly, now: now))
        // A removal waiting for an answer isn't in the playlist by definition.
        let asked = row(.synced, appleId: "i.9", flag: .removedFromAppleMusic)
        #expect(UnchangedCheck.canSkip(stored: token(), live: token(), rows: [asked], liveAppleIds: ["i.1"], recheck: .weekly, now: now))
    }
}
