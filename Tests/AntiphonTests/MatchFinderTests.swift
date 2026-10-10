import Foundation
import Synchronization
import Testing
@testable import Antiphon

/// A catalog with canned answers that records what it was asked.
final class FakeCatalog: TrackCatalog, Sendable {
    let platform: Platform
    private let byISRC: [String: [CatalogTrack]]
    private let searchResults: [CatalogTrack]
    private let calls = Mutex<[String]>([])

    init(platform: Platform = .appleMusic, byISRC: [String: [CatalogTrack]] = [:], searchResults: [CatalogTrack] = []) {
        self.platform = platform
        self.byISRC = byISRC
        self.searchResults = searchResults
    }

    var recordedCalls: [String] { calls.withLock { $0 } }

    func tracks(withISRC isrc: String) async throws -> [CatalogTrack] {
        calls.withLock { $0.append("isrc:\(isrc)") }
        return byISRC[isrc] ?? []
    }

    func search(_ query: String, limit: Int) async throws -> [CatalogTrack] {
        calls.withLock { $0.append("search:\(query)") }
        return Array(searchResults.prefix(limit))
    }
}

@Suite("Match finder")
struct MatchFinderTests {

    private let source = CatalogTrack(
        platform: .spotify, id: "spotify:track:mc", title: "Midnight City", artist: "M83",
        durationMs: 243_000, isrc: "FR6V81100040"
    )

    private func am(_ id: String, _ title: String, isrc: String? = nil, seconds: Int = 243) -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: title, artist: "M83", durationMs: seconds * 1000, isrc: isrc)
    }

    @Test("An ISRC hit is a certain match and skips the search")
    func isrcHit() async throws {
        let catalog = FakeCatalog(byISRC: ["FR6V81100040": [am("1", "Midnight City", isrc: "FR6V81100040")]])
        let outcome = try await MatchFinder.find(source, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.confidence == 100)
        #expect(outcome.best?.reason == .isrc)
        #expect(catalog.recordedCalls == ["isrc:FR6V81100040"])
    }

    @Test("Without an ISRC hit, search results are scored and ranked")
    func searchRanked() async throws {
        let catalog = FakeCatalog(searchResults: [
            am("live", "Midnight City (Live)", seconds: 262),
            am("remaster", "Midnight City (Remaster)", seconds: 244),
            am("remix", "Midnight City (Eric Prydz Remix)", seconds: 410)
        ])
        let outcome = try await MatchFinder.find(source, in: catalog, targetPlaylist: [])
        #expect(outcome.best?.track.id == "remaster")
        #expect(outcome.best?.reason == .versionDifference)
        #expect(outcome.alternatives.map(\.track.id) == ["live", "remix"] || outcome.alternatives.map(\.track.id) == ["remix", "live"])
        #expect(catalog.recordedCalls == ["isrc:FR6V81100040", "search:m83 midnight city"])
    }

    @Test("Synthetic local ISRCs go straight to search")
    func localISRC() async throws {
        var local = source
        local.isrc = "local-spotify:track:mc"
        let catalog = FakeCatalog(searchResults: [am("1", "Midnight City")])
        _ = try await MatchFinder.find(local, in: catalog, targetPlaylist: [])
        #expect(catalog.recordedCalls == ["search:m83 midnight city"])
    }

    @Test("No results means no match")
    func nothingFound() async throws {
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(), targetPlaylist: [])
        #expect(outcome.best == nil)
        #expect(outcome.alternatives.isEmpty)
        #expect(outcome.alreadyInTarget == false)
    }

    @Test("A match already in the target playlist is reported, by ID or ISRC")
    func alreadyInTarget() async throws {
        let hit = am("1", "Midnight City", isrc: "FR6V81100040")
        let catalog = FakeCatalog(byISRC: ["FR6V81100040": [hit]])

        let byId = try await MatchFinder.find(source, in: catalog, targetPlaylist: [hit])
        #expect(byId.alreadyInTarget)

        let libraryCopy = am("l.99", "Midnight City", isrc: "FR6V81100040")
        let byISRC = try await MatchFinder.find(source, in: catalog, targetPlaylist: [libraryCopy])
        #expect(byISRC.alreadyInTarget)

        let other = am("l.5", "Something Else")
        let notThere = try await MatchFinder.find(source, in: catalog, targetPlaylist: [other])
        #expect(notThere.alreadyInTarget == false)
    }

    @Test("At most five candidates are kept")
    func capsCandidates() async throws {
        let results = (0..<8).map { am("\($0)", "Midnight City (Version \($0))") }
        let outcome = try await MatchFinder.find(source, in: FakeCatalog(searchResults: results), targetPlaylist: [])
        #expect(outcome.alternatives.count <= 4)
    }
}
