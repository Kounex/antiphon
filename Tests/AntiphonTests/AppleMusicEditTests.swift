import Foundation
import Testing
@testable import Antiphon

@Suite("Apple Music playlist edits")
struct AppleMusicEditTests {

    @Test("Apple Music playlists Antiphon created can be edited directly; others stay guided")
    func capabilitiesPerSeam() {
        #expect(PlatformCapabilities.forSeam(appleMusicCreatedByAntiphon: true) == .full)
        #expect(PlatformCapabilities.forSeam(appleMusicCreatedByAntiphon: false) == .spotifyOnly)
    }

    private func entry(_ ids: String..., isrc: String? = nil) -> PlaylistEntryEdit.Entry {
        PlaylistEntryEdit.Entry(ids: Set(ids), isrc: isrc)
    }

    private func track(_ id: String, isrc: String? = nil) -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: "T", artist: "A", isrc: isrc)
    }

    @Test("Removing keeps every other entry, in order")
    func removeByID() throws {
        let entries = [entry("e1", "i.1"), entry("e2", "i.2"), entry("e3", "i.3")]
        let kept = try PlaylistEntryEdit.keptIndices(entries: entries, expectedCount: 3, removing: [track("i.2")])
        #expect(kept == [0, 2])
    }

    @Test("A catalog ID or ISRC finds the entry too")
    func removeByCatalogIdOrISRC() throws {
        let entries = [entry("e1", "i.1", "1440", isrc: "AAA"), entry("e2", "i.2", isrc: "BBB")]
        #expect(try PlaylistEntryEdit.keptIndices(entries: entries, expectedCount: 2, removing: [track("1440")]) == [1])
        #expect(try PlaylistEntryEdit.keptIndices(entries: entries, expectedCount: 2, removing: [track("x", isrc: "bbb")]) == [0])
    }

    @Test("Each removal takes out one entry, so a duplicate stays")
    func duplicates() throws {
        let entries = [entry("e1", "i.1"), entry("e2", "i.1")]
        #expect(try PlaylistEntryEdit.keptIndices(entries: entries, expectedCount: 2, removing: [track("i.1")]) == [1])
    }

    @Test("Refuses to rewrite a playlist it didn't fully read")
    func incompleteRead() {
        let entries = [entry("e1"), entry("e2")]
        #expect(throws: PlaylistEntryEdit.Failure.incompleteRead(read: 2, expected: 3)) {
            try PlaylistEntryEdit.keptIndices(entries: entries, expectedCount: 3, removing: [track("e1")])
        }
    }

    @Test("Refuses when nothing to remove was found")
    func nothingFound() {
        #expect(throws: PlaylistEntryEdit.Failure.notFound) {
            try PlaylistEntryEdit.keptIndices(entries: [entry("e1")], expectedCount: 1, removing: [track("zzz")])
        }
    }
}
