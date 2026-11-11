import Testing
@testable import Antiphon

@Suite("Confidence scorer")
struct ConfidenceScorerTests {

    private func track(
        _ title: String,
        artist: String = "M83",
        seconds: Int? = 243,
        isrc: String? = nil,
        explicit: Bool? = nil,
        platform: Platform = .appleMusic
    ) -> CatalogTrack {
        CatalogTrack(
            platform: platform, id: title, title: title, artist: artist,
            durationMs: seconds.map { $0 * 1000 }, isrc: isrc, isExplicit: explicit
        )
    }

    private let source = CatalogTrack(
        platform: .spotify, id: "spotify:track:1", title: "Midnight City", artist: "M83",
        durationMs: 243_000, isrc: "FR6V81100040", isExplicit: false
    )

    private func pair(_ titleA: String, _ artistA: String, _ titleB: String, _ artistB: String) -> MatchScore {
        ConfidenceScorer.score(source: track(titleA, artist: artistA, platform: .spotify), candidate: track(titleB, artist: artistB))
    }

    @Test("Spelling the catalogs disagree on isn't a difference: accents, & / and / +, Pt. / Part")
    func spellingVariants() {
        #expect(pair("Halo", "Beyoncé", "Halo", "Beyonce") == MatchScore(confidence: 99, reason: .titleArtistDuration))
        #expect(pair("Hoppípolla", "Sigur Rós", "Hoppipolla", "Sigur Ros").confidence == 99)
        #expect(pair("The Boxer", "Simon & Garfunkel", "The Boxer", "Simon and Garfunkel").confidence == 99)
        #expect(pair("Dog Days Are Over", "Florence + The Machine", "Dog Days Are Over", "Florence and the Machine").confidence == 99)
        #expect(pair("Another Brick in the Wall, Pt. 2", "Pink Floyd", "Another Brick in the Wall (Part 2)", "Pink Floyd").confidence == 99)
        #expect(pair("Help!", "The Beatles", "Help!", "Beatles").confidence == 99)
    }

    @Test("One side crediting more artists than the other is still a strong match")
    func creditedArtists() {
        #expect(pair("One Kiss", "Calvin Harris", "One Kiss", "Calvin Harris & Dua Lipa").confidence == 90)
        #expect(pair("Titanium", "David Guetta", "Titanium", "David Guetta, Sia").confidence == 90)
        #expect(pair("Refugee", "Tom Petty", "Refugee", "Tom Petty and the Heartbreakers").confidence == 90)
    }

    @Test("An artist name that only contains the other is asked about, never added on its own")
    func tributeActsAreAsked() {
        // The original isn't in the catalog; the search finds a tribute act.
        let tribute = pair("Halo", "Beyoncé", "Halo", "Beyoncé Tribute Band")
        #expect(tribute.confidence < ConfidencePolicy.defaultAutoAddThreshold)
        #expect(tribute.confidence >= ConfidencePolicy.reviewFloor)
        // Same band, credited differently: also a question, not a miss.
        let hendrix = pair("Purple Haze", "Jimi Hendrix", "Purple Haze", "The Jimi Hendrix Experience")
        #expect(hendrix.confidence >= ConfidencePolicy.reviewFloor && hendrix.confidence < 90)
    }

    @Test("Same ISRC is a certain match")
    func isrcMatch() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City", isrc: "fr6v81100040"))
        #expect(result == MatchScore(confidence: 100, reason: .isrc))
    }

    @Test("Same title, artist and duration within 2 s adds automatically")
    func titleArtistDuration() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City", seconds: 245))
        #expect(result.reason == .titleArtistDuration)
        #expect(result.confidence >= 90)
        #expect(result.confidence < 100)
    }

    @Test("A remaster of the same song lands in the review band")
    func remasterNeedsReview() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City (Remaster)", seconds: 244))
        #expect(result.reason == .versionDifference)
        #expect(ConfidencePolicy().band(for: result.confidence) == .review)
    }

    @Test("Live versions and remixes fall below the review floor")
    func liveAndRemixAreAlternatives() {
        let live = ConfidenceScorer.score(source: source, candidate: track("Midnight City (Live)", seconds: 262))
        let remix = ConfidenceScorer.score(source: source, candidate: track("Midnight City (Eric Prydz Remix)", seconds: 410))
        #expect(live.reason == .versionDifference)
        #expect(live.confidence < ConfidencePolicy.reviewFloor)
        #expect(remix.confidence < ConfidencePolicy.reviewFloor)
    }

    @Test("Same tags on both sides are not a version difference")
    func sameVersionOnBothSides() {
        let liveSource = CatalogTrack(platform: .spotify, id: "s", title: "Holocene - Live", artist: "Bon Iver", durationMs: 330_000)
        let result = ConfidenceScorer.score(
            source: liveSource,
            candidate: track("Holocene (Live)", artist: "Bon Iver", seconds: 331)
        )
        #expect(result.reason == .titleArtistDuration)
        #expect(result.confidence >= 90)
    }

    @Test("A duration more than 2 s off is treated as a different version")
    func durationOffIsVersionDifference() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City", seconds: 252))
        #expect(result.reason == .versionDifference)
        #expect(result.confidence < 90)
    }

    @Test("Explicit vs clean counts as a version difference")
    func explicitMismatch() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City", explicit: true))
        #expect(result.reason == .versionDifference)
        #expect(ConfidencePolicy().band(for: result.confidence) == .review)
    }

    @Test("Title-only matches are never good enough to review")
    func titleOnly() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City", artist: "Someone Else"))
        #expect(result.reason == .titleOnly)
        #expect(result.confidence < ConfidencePolicy.reviewFloor)
    }

    @Test("Featured artists on one side still count as the same artist")
    func featuredArtistPartialMatch() {
        let guetta = CatalogTrack(platform: .spotify, id: "s", title: "Titanium (feat. Sia)", artist: "David Guetta", durationMs: 245_000)
        let result = ConfidenceScorer.score(
            source: guetta,
            candidate: track("Titanium", artist: "David Guetta & Sia", seconds: 245)
        )
        #expect(result.confidence >= ConfidencePolicy.reviewFloor)
    }

    @Test("Unknown durations don't count against a match")
    func unknownDuration() {
        let result = ConfidenceScorer.score(source: source, candidate: track("Midnight City", seconds: nil))
        #expect(result.reason == .titleArtistDuration)
        #expect(result.confidence >= 90)
    }
}
