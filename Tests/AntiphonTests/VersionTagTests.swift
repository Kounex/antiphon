import Testing
@testable import Antiphon

@Suite("Version tags")
struct VersionTagTests {

    @Test("Plain title has no tags and normalizes to itself")
    func plainTitle() {
        let parsed = VersionTag.parse("Midnight City")
        #expect(parsed.tags.isEmpty)
        #expect(parsed.baseTitle == "midnight city")
    }

    @Test("Remaster in parentheses or after a dash is a tag, not part of the title")
    func remaster() {
        #expect(VersionTag.parse("Midnight City (Remaster)").tags == [.remaster])
        #expect(VersionTag.parse("Midnight City - 2018 Remastered Version").tags == [.remaster])
        #expect(VersionTag.parse("Midnight City (Remaster)").baseTitle == "midnight city")
    }

    @Test("Live only counts inside a version segment, never in the song name")
    func liveOnlyInSegments() {
        #expect(VersionTag.parse("Midnight City (Live)").tags == [.live])
        #expect(VersionTag.parse("Live Forever").tags.isEmpty)
        #expect(VersionTag.parse("Live Forever").baseTitle == "live forever")
    }

    @Test("Remixes keep their label so two different remixes differ")
    func remixLabel() {
        let prydz = VersionTag.parse("Midnight City (Eric Prydz Remix)")
        let other = VersionTag.parse("Midnight City [Other Remix]")
        #expect(prydz.tags == [.remix("eric prydz remix")])
        #expect(prydz.tags != other.tags)
        #expect(VersionTag.parse("Edge (Blanke Remix)").tags == VersionTag.parse("Edge - Blanke Remix").tags)
    }

    @Test("Radio edits, acoustic, instrumental, demo and clean versions are recognized")
    func otherTags() {
        #expect(VersionTag.parse("Song (Radio Edit)").tags == [.radioEdit])
        #expect(VersionTag.parse("Song - Acoustic").tags == [.acoustic])
        #expect(VersionTag.parse("Song (Instrumental)").tags == [.instrumental])
        #expect(VersionTag.parse("Song [Demo]").tags == [.demo])
        #expect(VersionTag.parse("Song (Clean)").tags == [.clean])
    }

    @Test("Promotional junk is stripped, not treated as a version")
    func promoJunk() {
        let parsed = VersionTag.parse("Song (Official Video)")
        #expect(parsed.tags.isEmpty)
        #expect(parsed.baseTitle == "song")
    }

    @Test("Featuring credits don't change the base title")
    func featuring() {
        #expect(VersionTag.parse("Titanium (feat. Sia)").baseTitle == "titanium")
        #expect(VersionTag.parse("Titanium (feat. Sia)").tags.isEmpty)
    }
}
