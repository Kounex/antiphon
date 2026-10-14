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

@Suite("Original album preference")
struct OriginalAlbumTests {
    private let original = VersionPreferences(release: .original)

    private func am(_ id: String, album: String, year: Int, isrc: String = "USWB10002407") -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: "In the End", artist: "Linkin Park", album: album,
                     durationMs: 216_000, isrc: isrc, releaseYear: year)
    }

    private let fromCompilation = CatalogTrack(platform: .spotify, id: "s", title: "In the End", artist: "Linkin Park",
                                               album: "Greatest Hits", durationMs: 216_000, isrc: "USWB10002407")

    @Test("A source on a compilation gets the studio album")
    func compilationSourceGetsStudioAlbum() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("hits", album: "Greatest Hits", year: 2023), am("studio", album: "Hybrid Theory", year: 2000)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "studio")
    }

    @Test("The default still follows the source's album")
    func defaultFollowsSource() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("hits", album: "Greatest Hits", year: 2023), am("studio", album: "Hybrid Theory", year: 2000)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.track.id == "hits")
    }

    @Test("The standard edition beats the deluxe one from the same year")
    func standardOverDeluxe() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("deluxe", album: "Hybrid Theory (Deluxe Edition)", year: 2000), am("studio", album: "Hybrid Theory", year: 2000)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "studio")
    }

    @Test("The album beats the single, even when the single came first")
    func albumOverSingle() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("single", album: "In the End - Single", year: 1999), am("studio", album: "Hybrid Theory", year: 2000)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "studio")
    }

    @Test("Only compilations: the earliest one")
    func onlyCompilations() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("later", album: "Rock Anthems 2000s", year: 2019), am("first", album: "Greatest Hits", year: 2004)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "first")
    }

    @Test("When the ISRC only finds compilations, a search looks for the studio album")
    func searchesForStudioAlbum() async throws {
        let catalog = FakeCatalog(
            byISRC: ["USWB10002407": [am("hits", album: "Greatest Hits", year: 2023)]],
            searchResults: [am("studio", album: "Hybrid Theory", year: 2000, isrc: "USWB19900001")]
        )
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "studio")
        #expect(catalog.recordedCalls == ["isrc:USWB10002407", "search:linkin park in the end", "kinds:2"])
    }

    @Test("A song that first came out on a compilation keeps that compilation over its single")
    func compilationOriginal() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("single", album: "Word Up! - Single", year: 2004), am("hits", album: "Greatest Hits, Vol. 1", year: 2004)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "hits")
    }

    @Test("A single that came out before any compilation is the original")
    func standaloneSingle() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [
            am("best", album: "The Best Of", year: 2015), am("single", album: "In the End - Single", year: 2010)
        ]])
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "single")
    }

    @Test("A various-artists compilation without a telling title is known by the catalog's album type")
    func catalogCompilation() async throws {
        let catalog = FakeCatalog(
            byISRC: ["USWB10002407": [am("hard-rock", album: "It's Hard Rock, Hallelujah!", year: 2004),
                                      am("hits", album: "Greatest Hits", year: 2004)]],
            albumKinds: ["hard-rock": .compilation]
        )
        let outcome = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [], preferences: original)
        #expect(outcome.best?.track.id == "hits")
    }

    @Test("Album types are only looked up for the original album")
    func kindsOnlyWhenNeeded() async throws {
        let catalog = FakeCatalog(byISRC: ["USWB10002407": [am("hits", album: "Greatest Hits", year: 2004)]])
        _ = try await MatchFinder.find(fromCompilation, in: catalog, targetPlaylist: [])
        #expect(!catalog.recordedCalls.contains { $0.hasPrefix("kinds:") })
    }

    @Test("Spotify's album type comes along with the track")
    func spotifyAlbumType() throws {
        let json = #"{"id":"x","name":"Word Up!","uri":"spotify:track:x","duration_ms":173000,"type":"track","album":{"id":"a","name":"It's Hard Rock, Hallelujah!","album_type":"compilation"}}"#
        let track = try JSONDecoder().decode(SpotifyTrack.self, from: Data(json.utf8))
        #expect(CatalogTrack(track).albumKind == .compilation)
    }

    // The device probe from 2026-10-14 (selftest matchprobe): Spotify's "Word Up!"
    // on its remixes EP. Apple Music returns nine releases for the ISRC, all 100%.

    private func korn(_ id: String, album: String, kind: AlbumKind? = nil, platform: Platform = .appleMusic) -> CatalogTrack {
        var track = CatalogTrack(platform: platform, id: id, title: "Word Up!", artist: "Korn", album: album,
                                 durationMs: 172_000, isrc: "USSM10411917", releaseYear: 2004)
        track.albumKind = kind
        return track
    }

    private var kornOnAppleMusic: [CatalogTrack] {
        [korn("fitness", album: "Pure... Fitness"), korn("hallelujah", album: "It's Hard Rock, Hallelujah!"),
         korn("rock", album: "Pure... Rock"), korn("ep", album: "Word Up!: The Remixes - EP"),
         korn("hits", album: "Greatest Hits, Vol. 1"), korn("laut", album: "Life & Style Music: Laut")]
    }

    @Test("Each catalog's name for the same EP is the same album",
          arguments: [("Word Up! (The Remixes)", "Word Up!: The Remixes - EP"),
                      ("Word Up!: The Remixes - EP", "Word Up! (The Remixes)"),
                      ("Hybrid Theory", "Hybrid Theory - EP"),
                      ("Lost", "Lost - Single")])
    func catalogNamingSameAlbum(spotify: String, apple: String) {
        #expect(ReleasePreference.albumMatch(korn("a", album: apple), korn("s", album: spotify, platform: .spotify)) > 0)
    }

    @Test("Different albums still don't match", arguments: [("Word Up! (The Remixes)", "Greatest Hits, Vol. 1"),
                                                             ("Meteora", "Hybrid Theory"),
                                                             ("Word Up! (The Remixes)", "Pure... Rock")])
    func differentAlbums(spotify: String, apple: String) {
        #expect(ReleasePreference.albumMatch(korn("a", album: apple), korn("s", album: spotify, platform: .spotify)) == 0)
    }

    @Test("Same as source: Word Up! from the remixes EP gets the remixes EP, not a compilation")
    func kornRemixesEP() async throws {
        let source = korn("s", album: "Word Up! (The Remixes)", kind: .single, platform: .spotify)
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(byISRC: ["USSM10411917": kornOnAppleMusic]), targetPlaylist: [])
        #expect(outcome.best?.track.id == "ep")
    }

    @Test("Same as source, the album isn't on the other side: compilations Apple doesn't name as such still lose")
    func sourceAlbumMissingSkipsUnnamedCompilations() async throws {
        let source = korn("s", album: "Word Up! (The Remixes)", kind: .single, platform: .spotify)
        let withoutEP = kornOnAppleMusic.filter { $0.id != "ep" } + [korn("studio", album: "Untouchables")]
        let kinds: [String: AlbumKind] = ["fitness": .compilation, "hallelujah": .compilation, "rock": .compilation,
                                          "hits": .compilation, "laut": .compilation, "studio": .album]
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(byISRC: ["USSM10411917": withoutEP], albumKinds: kinds),
                                                 targetPlaylist: [])
        #expect(outcome.best?.track.id == "studio")
    }

    @Test("Original: Apple Music's lookups give the song's year, so the album's own year decides (Greatest Hits 2004, not Pure... Fitness 2013)")
    func originalUsesAlbumYears() async throws {
        let source = korn("s", album: "Word Up! (The Remixes)", kind: .single, platform: .spotify)
        let catalog = FakeCatalog(
            byISRC: ["USSM10411917": kornOnAppleMusic],
            albumKinds: ["fitness": .compilation, "hallelujah": .compilation, "rock": .compilation, "ep": .single,
                         "hits": .compilation, "laut": .compilation],
            albumYears: ["fitness": 2013, "hallelujah": 2006, "rock": 2012, "ep": 2004, "hits": 2004, "laut": 2008]
        )
        let outcome = try await MatchFinder.find(source, in: catalog, targetPlaylist: [], preferences: VersionPreferences(release: .original))
        #expect(outcome.best?.track.id == "hits")
    }

    @Test("Same as source, the album is there: no release types are looked up")
    func sourceAlbumFoundNoLookup() async throws {
        let source = korn("s", album: "Word Up! (The Remixes)", kind: .single, platform: .spotify)
        let catalog = FakeCatalog(byISRC: ["USSM10411917": kornOnAppleMusic])
        _ = try await MatchFinder.find(source, in: catalog, targetPlaylist: [])
        #expect(!catalog.recordedCalls.contains { $0.hasPrefix("kinds:") })
    }

    @Test("Edition and single titles are recognized")
    func titles() {
        #expect(ReleasePreference.isSpecialEdition("Hybrid Theory (20th Anniversary Edition)"))
        #expect(ReleasePreference.isSpecialEdition("Meteora (Deluxe)"))
        #expect(!ReleasePreference.isSpecialEdition("Hybrid Theory"))
        #expect(ReleasePreference.isSingle("In the End - Single"))
        #expect(ReleasePreference.isSingle("Lost - EP"))
        #expect(!ReleasePreference.isSingle("Hybrid Theory"))
    }
}
