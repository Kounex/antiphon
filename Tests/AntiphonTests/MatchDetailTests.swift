import Foundation
import Testing
@testable import Antiphon

@Suite("Match detail")
struct MatchDetailTests {

    private let source = CatalogTrack(platform: .spotify, id: "s", title: "Midnight City", artist: "M83",
                                      album: "Hurry Up, We're Dreaming", durationMs: 243_000, isrc: "FR6V81100040", isExplicit: false)
    private let remaster = CatalogTrack(platform: .appleMusic, id: "a", title: "Midnight City (Remaster)", artist: "M83",
                                        album: "Hurry Up, We're Dreaming (2018)", durationMs: 244_000, isrc: "FR6V81800112", isExplicit: false)

    @Test("Fields are compared side by side; differences are flagged")
    func comparison() {
        let rows = MatchComparison.rows(source: source, candidate: remaster)
        #expect(rows.map(\.label) == ["Title", "Artist", "Album", "Length", "Explicit", "ISRC"])
        #expect(rows.map(\.differs) == [true, false, true, false, false, true])
        #expect(rows[3].left == "4:03")
        #expect(rows[3].right == "4:04")
        #expect(rows[4].left == "No")
        #expect(rows[5].isCode)
    }

    @Test("Unknown values show a dash and never count as a difference")
    func unknowns() {
        var bare = remaster
        bare.isrc = nil
        bare.isExplicit = nil
        let rows = MatchComparison.rows(source: source, candidate: bare)
        #expect(rows[4].right == "–")
        #expect(rows[5].right == "–")
        #expect(rows[5].differs == false)
    }

    @Test("Preferring remasters makes a remaster as good as the original")
    func preferRemasters() {
        let normal = ConfidenceScorer.score(source: source, candidate: remaster)
        let preferring = ConfidenceScorer.score(source: source, candidate: remaster,
                                                preferences: VersionPreferences(acceptRemasters: true))
        #expect(ConfidencePolicy().band(for: normal.confidence) == .review)
        #expect(ConfidencePolicy().band(for: preferring.confidence) == .automatic)
    }

    @Test("The review queue is on: 60–89% matches wait for the person")
    func bandsOn() {
        let defaults = UserDefaults(suiteName: "bands-\(UUID().uuidString)")!
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.reviewQueueEnabled)
        #expect(prefs.confidencePolicy.band(for: 86) == .review)
        #expect(prefs.versionPreferences == VersionPreferences(acceptRemasters: false))
        prefs.acceptRemasters = true
        #expect(prefs.versionPreferences.acceptRemasters)
    }
}
