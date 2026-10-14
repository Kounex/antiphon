import SwiftUI
import Testing
import AntiphonDesign

@Suite("Design components")
@MainActor
struct DesignComponentTests {

    private let watching = SyncCard.Status(isMonitoring: true)

    @Test("The border marks special states; all good has none")
    func borderTone() {
        let good = SeamHealth(synced: 6, review: 0, missing: 0, total: 6)
        let review = SeamHealth(synced: 4, review: 2, missing: 0, total: 6)
        #expect(SyncCard.tone(health: good, status: watching) == nil)
        #expect(SyncCard.tone(health: good, status: .init(isMonitoring: true, isPaused: true)) == nil)
        #expect(SyncCard.tone(health: review, status: watching) == .review)
        #expect(SyncCard.tone(health: good, status: .init(isMonitoring: true, failure: "Failed")) == .failed)
        #expect(SyncCard.tone(health: good, status: .init(isMonitoring: true, isChecking: true)) == .checking)
        #expect(SyncCard.tone(health: good, status: .init(isMonitoring: true, isSyncing: true)) == .syncing)
    }

    @Test("Activity wins the border: syncing, checking, then failed, then review")
    func borderPriority() {
        let review = SeamHealth(synced: 4, review: 2, missing: 0, total: 6)
        #expect(SyncCard.tone(health: review, status: .init(isMonitoring: true, isSyncing: true, isChecking: true, failure: "Failed")) == .syncing)
        #expect(SyncCard.tone(health: review, status: .init(isMonitoring: true, isChecking: true, failure: "Failed")) == .checking)
        #expect(SyncCard.tone(health: review, status: .init(isMonitoring: true, failure: "Failed")) == .failed)
        #expect(SyncCard.Tone.syncing.isActive && SyncCard.Tone.checking.isActive)
        #expect(!SyncCard.Tone.failed.isActive && !SyncCard.Tone.review.isActive)
    }

    @Test("The knot shows what the seam is doing right now")
    func knot() {
        #expect(SyncCard.knot(status: watching) == .direction)
        #expect(SyncCard.knot(status: .init(isMonitoring: true, isChecking: true)) == .checking)
        #expect(SyncCard.knot(status: .init(isMonitoring: true, isSyncing: true, isChecking: true, failure: "Failed")) == .syncing)
        #expect(SyncCard.knot(status: .init(isMonitoring: true, isPaused: true)) == .paused)
        #expect(SyncCard.knot(status: .init(isMonitoring: true, isPaused: true, failure: "Failed")) == .problem)
        #expect(SyncCard.knot(status: .init(isMonitoring: false, isSyncing: true, isPaused: true)) == .syncing)
    }

    @Test("Storyboard card shows Review 3 and Watching")
    func reviewAndWatching() {
        let health = SeamHealth(synced: 48, review: 3, missing: 1, total: 52)
        #expect(SyncCard.pills(health: health, status: watching) == [.review(3), .monitoring])
    }

    @Test("A failure always comes first, and never with In sync")
    func failureFirst() {
        let health = SeamHealth(synced: 10, review: 0, missing: 0, total: 10)
        let status = SyncCard.Status(isMonitoring: true, failure: "Sign in")
        #expect(SyncCard.pills(health: health, status: status) == [.failed("Sign in"), .monitoring])
    }

    @Test("At most two pills, by priority")
    func capsAtTwo() {
        let health = SeamHealth(synced: 1, review: 2, missing: 0, total: 3)
        let status = SyncCard.Status(isMonitoring: true, isSyncing: true, failure: "Failed")
        #expect(SyncCard.pills(health: health, status: status) == [.failed("Failed"), .review(2)])
    }

    @Test("Fully synced, not watching: just In sync")
    func inSyncOnly() {
        let health = SeamHealth(synced: 117, review: 0, missing: 0, total: 117)
        #expect(SyncCard.pills(health: health, status: .init(isMonitoring: false)) == [.inSync])
    }

    @Test("Paused replaces Watching")
    func paused() {
        let health = SeamHealth(synced: 5, review: 0, missing: 1, total: 6)
        #expect(SyncCard.pills(health: health, status: .init(isMonitoring: true, isPaused: true)) == [.paused])
    }

    @Test("Checking takes the watching pill's place while the app reads the playlists")
    func checking() {
        let health = SeamHealth(synced: 6, review: 0, missing: 0, total: 6)
        #expect(SyncCard.pills(health: health, status: .init(isMonitoring: true, isChecking: true)) == [.checking, .inSync])
        #expect(SyncCard.pills(health: health, status: .init(isMonitoring: false, isChecking: true)) == [.checking, .inSync])
        #expect(SyncCard.pills(health: health, status: .init(isMonitoring: true, isChecking: true, isPaused: true)) == [.paused, .inSync])
    }

    @Test("Health bar fractions and VoiceOver value")
    func healthBar() {
        let health = SeamHealth(synced: 48, review: 3, missing: 1, total: 52)
        #expect(abs(health.fractions.synced - 48.0 / 52) < 0.0001)
        #expect(health.accessibilityValue == "48 synced, 3 to review, 1 missing")
        #expect(SeamHealth(synced: 0, review: 0, missing: 0, total: 0).fractions.synced == 0)
    }

    @Test("Confidence meter bands follow the threshold")
    func bands() {
        #expect(ConfidenceMeter.band(90) == .automatic)
        #expect(ConfidenceMeter.band(86) == .review)
        #expect(ConfidenceMeter.band(48) == .alternative)
        #expect(ConfidenceMeter.band(84, threshold: 80) == .automatic)
    }

    @Test("Placeholder covers are stable and always blend two different fields")
    func placeholderCovers() {
        for seed in ["Late Night Drive", "Garden Sundays", "Run Club", "", "x"] {
            let (a, b) = CoverPlaceholder.fields(for: seed)
            #expect(a != b)
            let again = CoverPlaceholder.fields(for: seed)
            #expect(again.0 == a && again.1 == b)
        }
    }

    @Test("Track row symbols carry the state, not only color")
    func trackRowSymbols() {
        #expect(TrackRow.symbolName(.synced) == "checkmark.circle.fill")
        #expect(TrackRow.symbolName(.review(confidence: 86)) == "questionmark.circle.fill")
        #expect(TrackRow.symbolName(.missing) == "circle.slash")
        #expect(TrackRow.symbolName(.failed) == "exclamationmark.triangle.fill")
        #expect(TrackRow.stateDescription(.review(confidence: 86)) == "Needs review, 86% match")
    }
}
