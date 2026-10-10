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

/// The device cases from 2026-10-10: Apple's original-album releases often
/// carry different ISRCs than Spotify's, so ISRC lookups only find compilations.
@Suite("Original album found by search")
struct AlbumSearchTests {

    private func am(_ id: String, _ title: String, album: String, seconds: Int, isrc: String?) -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: title, artist: "Linkin Park", album: album,
                     durationMs: seconds * 1000, isrc: isrc, releaseYear: 2019)
    }

    private let faint = CatalogTrack(platform: .spotify, id: "s-faint", title: "Faint", artist: "Linkin Park",
                                     album: "Meteora", durationMs: 162_000, isrc: "USWB10300468")

    @Test("Faint: the Meteora version found by search beats same-ISRC compilations")
    func faintOnMeteora() async throws {
        let catalog = FakeCatalog(
            byISRC: ["USWB10300468": [
                am("comp1", "Faint", album: "Home of Music Rock", seconds: 162, isrc: "USWB10300468"),
                am("comp2", "Faint", album: "POP MOMENTS 2025", seconds: 162, isrc: "USWB10300468")
            ]],
            searchResults: [am("meteora", "Faint", album: "Meteora", seconds: 163, isrc: "USWB12300111")]
        )
        let outcome = try await MatchFinder.find(faint, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.track.id == "meteora")
        #expect((outcome.best?.confidence ?? 0) >= 90)
        #expect(catalog.recordedCalls == ["isrc:USWB10300468", "search:linkin park faint meteora"])
    }

    @Test("A different-length album version never beats an exact ISRC match")
    func differentVersionLoses() async throws {
        let catalog = FakeCatalog(
            byISRC: ["USWB10300468": [am("comp1", "Faint", album: "Home of Music Rock", seconds: 162, isrc: "USWB10300468")]],
            searchResults: [am("meteora-live", "Faint (Live)", album: "Meteora", seconds: 175, isrc: nil)]
        )
        let outcome = try await MatchFinder.find(faint, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.track.id == "comp1")
    }

    @Test("No extra search when an ISRC release is already on the source's album")
    func noExtraSearch() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10300468": [am("meteora", "Faint", album: "Meteora", seconds: 162, isrc: "USWB10300468")]])
        let outcome = try await MatchFinder.find(faint, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.track.id == "meteora")
        #expect(catalog.recordedCalls == ["isrc:USWB10300468"])
    }

    @Test("Heavy Is the Crown: plain From Zero beats the Deluxe Edition")
    func exactAlbumBeatsEdition() async throws {
        let source = CatalogTrack(platform: .spotify, id: "s", title: "Heavy Is the Crown", artist: "Linkin Park",
                                  album: "From Zero", durationMs: 167_000, isrc: "USWB12403466")
        let catalog = FakeCatalog(byISRC: ["USWB12403466": [
            am("deluxe", "Heavy Is the Crown", album: "From Zero (Deluxe Edition)", seconds: 167, isrc: "USWB12403466"),
            am("plain", "Heavy Is the Crown", album: "From Zero", seconds: 167, isrc: "USWB12403466")
        ]])
        let outcome = try await MatchFinder.find(source, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.track.id == "plain")
    }

    @Test("Album match strength: exact, then edition, then none")
    func albumScores() {
        let source = CatalogTrack(platform: .spotify, id: "s", title: "T", artist: "A", album: "Meteora (Bonus Edition)")
        func score(_ album: String) -> Int {
            ReleasePreference.albumMatch(CatalogTrack(platform: .appleMusic, id: "x", title: "T", artist: "A", album: album), source)
        }
        #expect(score("Meteora (Bonus Edition)") == 3)
        #expect(score("Meteora") == 2)
        #expect(score("Meteora 20th Anniversary Edition") == 2)
        #expect(score("Home of Music Rock") == 0)
    }
}

@Suite("Putting a track back")
struct RestoreReleaseTests {
    @Test("A restored track gets its original album, not the first ISRC hit")
    func originalAlbum() async throws {
        let removed = CatalogTrack(platform: .appleMusic, id: "i.word", title: "Word Up!", artist: "Korn",
                                   album: "Greatest Hits, Vol. 1", durationMs: 173_000, isrc: "USSM10400583")
        let catalog = FakeCatalog(byISRC: ["USSM10400583": [
            CatalogTrack(platform: .appleMusic, id: "random", title: "Word Up!", artist: "Korn", album: "Nu Metal Hits",
                         durationMs: 173_000, isrc: "USSM10400583"),
            CatalogTrack(platform: .appleMusic, id: "original", title: "Word Up!", artist: "Korn", album: "Greatest Hits, Vol. 1",
                         durationMs: 173_000, isrc: "USSM10400583")
        ]])
        let picked = try await ReleaseResolver.catalogTrack(for: removed, in: catalog)
        #expect(picked?.id == "original")
    }

    @Test("Nothing solid enough means nothing is added")
    func noWeakPick() async throws {
        let removed = CatalogTrack(platform: .appleMusic, id: "i.x", title: "Word Up!", artist: "Korn", durationMs: 173_000)
        let catalog = FakeCatalog(searchResults: [
            CatalogTrack(platform: .appleMusic, id: "live", title: "Word Up! (Live)", artist: "Korn", durationMs: 200_000)
        ])
        #expect(try await ReleaseResolver.catalogTrack(for: removed, in: catalog) == nil)
    }
}
