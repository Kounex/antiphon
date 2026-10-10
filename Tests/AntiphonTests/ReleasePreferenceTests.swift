import Foundation
import Testing
@testable import Antiphon

@Suite("Original release preference")
struct ReleasePreferenceTests {

    private func am(_ id: String, album: String, year: Int) -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: "In the End", artist: "Linkin Park", album: album,
                     durationMs: 216_000, isrc: "USWB10002407", releaseYear: year)
    }

    private let releases: [CatalogTrack] = [
        CatalogTrack(platform: .appleMusic, id: "hits", title: "In the End", artist: "Linkin Park", album: "Greatest Hits",
                     durationMs: 216_000, isrc: "USWB10002407", releaseYear: 2023),
        CatalogTrack(platform: .appleMusic, id: "rock", title: "In the End", artist: "Linkin Park", album: "Rock Anthems 2000s",
                     durationMs: 216_000, isrc: "USWB10002407", releaseYear: 2019),
        CatalogTrack(platform: .appleMusic, id: "original", title: "In the End", artist: "Linkin Park", album: "Hybrid Theory",
                     durationMs: 216_000, isrc: "USWB10002407", releaseYear: 2000)
    ]

    @Test("Several releases share an ISRC: the source's own album wins")
    func sameAlbumWins() async throws {
        let source = CatalogTrack(platform: .spotify, id: "s", title: "In the End", artist: "Linkin Park",
                                  album: "Hybrid Theory (Bonus Edition)", durationMs: 216_000, isrc: "USWB10002407", releaseYear: 2000)
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(byISRC: ["USWB10002407": releases]), targetPlaylist: [])
        #expect(outcome.best?.track.id == "original")
        #expect(outcome.best?.confidence == 100)
    }

    @Test("Without an album to go by, the earliest non-compilation wins")
    func earliestOriginalWins() async throws {
        let source = CatalogTrack(platform: .spotify, id: "s", title: "In the End", artist: "Linkin Park",
                                  durationMs: 216_000, isrc: "USWB10002407")
        let shuffled = [releases[1], releases[0], releases[2]]
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(byISRC: ["USWB10002407": shuffled]), targetPlaylist: [])
        #expect(outcome.best?.track.id == "original")
    }

    @Test("A source that is itself on a compilation can match that compilation")
    func compilationSource() async throws {
        let source = CatalogTrack(platform: .spotify, id: "s", title: "In the End", artist: "Linkin Park",
                                  album: "Greatest Hits", durationMs: 216_000, isrc: "USWB10002407")
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(byISRC: ["USWB10002407": releases]), targetPlaylist: [])
        #expect(outcome.best?.track.id == "hits")
    }

    @Test("Compilation titles are recognized")
    func compilationTitles() {
        #expect(ReleasePreference.isCompilation("Greatest Hits"))
        #expect(ReleasePreference.isCompilation("The Very Best of Linkin Park"))
        #expect(ReleasePreference.isCompilation("Rock Anthems 2000s"))
        #expect(ReleasePreference.isCompilation("NOW That's What I Call Music! 52"))
        #expect(!ReleasePreference.isCompilation("Hybrid Theory"))
        #expect(!ReleasePreference.isCompilation("Meteora (Bonus Edition)"))
    }
}
