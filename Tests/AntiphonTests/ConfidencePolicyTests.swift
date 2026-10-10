import Testing
@testable import Antiphon

@Suite("Confidence bands")
struct ConfidencePolicyTests {

    @Test("Default threshold: 90 and above adds automatically")
    func defaultAutomaticBand() {
        let policy = ConfidencePolicy()
        #expect(policy.band(for: 100) == .automatic)
        #expect(policy.band(for: 90) == .automatic)
    }

    @Test("Default threshold: 60–89 goes to the review queue")
    func defaultReviewBand() {
        let policy = ConfidencePolicy()
        #expect(policy.band(for: 89) == .review)
        #expect(policy.band(for: 60) == .review)
    }

    @Test("Below 60 is never added, only shown as an alternative")
    func alternativeBand() {
        let policy = ConfidencePolicy()
        #expect(policy.band(for: 59) == .alternative)
        #expect(policy.band(for: 0) == .alternative)
    }

    @Test("Moving the threshold moves only the automatic boundary")
    func adjustedThreshold() {
        let policy = ConfidencePolicy(autoAddThreshold: 80)
        #expect(policy.band(for: 80) == .automatic)
        #expect(policy.band(for: 79) == .review)
        #expect(policy.band(for: 60) == .review)
        #expect(policy.band(for: 59) == .alternative)
    }

    @Test("Threshold can't drop below the review floor or exceed 100")
    func thresholdIsClamped() {
        #expect(ConfidencePolicy(autoAddThreshold: 20).autoAddThreshold == 60)
        #expect(ConfidencePolicy(autoAddThreshold: 140).autoAddThreshold == 100)
    }
}
