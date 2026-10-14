import Foundation
import Synchronization
import Testing
@testable import Antiphon

/// Answers every search with fixed results and records the queries.
final class FixedSearch: CatalogSearchService, Sendable {
    let results: [CatalogTrack]
    private let queries = Mutex<[String]>([])
    init(_ results: [CatalogTrack]) { self.results = results }
    var asked: [String] { queries.withLock { $0 } }
    func search(_ text: String, on platform: Platform) async throws -> [CatalogTrack] {
        queries.withLock { $0.append("\(platform.rawValue): \(text)") }
        return results.filter { $0.platform == platform }
    }
}

@Suite("Version picker")
@MainActor
struct VersionPickerTests {

    private let seam = SeamSummary(
        id: UUID(),
        spotify: SeamSide(platform: .spotify, playlistId: "s", name: "Remixes", artworkURL: nil),
        appleMusic: SeamSide(platform: .appleMusic, playlistId: "a", name: "Remixes AM", artworkURL: nil),
        direction: .spotifyToApple, isMonitored: true, isPaused: false, monitorIntervalMinutes: 15,
        lastCheckedAt: nil, lastResult: nil, counts: SeamCounts(synced: 1, review: 0, missing: 0, total: 1)
    )

    private let source = CatalogTrack(platform: .spotify, id: "spotify:track:wordup", title: "Word Up!", artist: "Korn",
                                      album: "Word Up! (The Remixes)", durationMs: 172_000, isrc: "USSM10411917")

    private func am(_ id: String, _ title: String = "Word Up!", album: String, length: Int = 172_000,
                    isrc: String = "USSM10411917") -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: id, title: title, artist: "Korn", album: album, durationMs: length, isrc: isrc)
    }

    private func target(_ current: PickTarget.Current, candidates: [MatchCandidate] = []) -> PickTarget {
        PickTarget(seam: seam, source: source, current: current, candidates: candidates)
    }

    @Test("The search starts with the song's artist and title")
    func prefilledQuery() {
        let model = VersionPickerModel(target: target(.notThere), search: FixedSearch([]), preferences: .standard)
        #expect(model.query == "Korn Word Up!")
    }

    @Test("Opening lists what's there now, then the matcher's candidates, then search results by score, each once")
    func order() async {
        let hits = am("i.hits", album: "Greatest Hits, Vol. 1")
        let ep = MatchCandidate(track: am("ep", album: "Word Up!: The Remixes - EP"), confidence: 100, reason: .isrc)
        let live = am("live", "Word Up! (Live)", album: "Live", length: 190_000, isrc: "USSM10500001")
        let search = FixedSearch([live, ep.track, am("rock", album: "Pure... Rock")])
        let model = VersionPickerModel(target: target(.antiphonsPick(hits), candidates: [ep]), search: search, preferences: .standard)

        await model.load()

        #expect(model.versions.map(\.track.id) == ["i.hits", "ep", "rock", "live"])
        #expect(search.asked == ["Apple Music: Korn Word Up!"])
        #expect(model.isCurrent(model.versions[0]))
    }

    @Test("What's there now is selected first; with nothing there, the best candidate")
    func defaultSelection() async {
        let hits = am("i.hits", album: "Greatest Hits, Vol. 1")
        let withCurrent = VersionPickerModel(target: target(.antiphonsPick(hits)), search: FixedSearch([]), preferences: .standard)
        await withCurrent.load()
        #expect(withCurrent.selected?.track.id == "i.hits")

        let ep = MatchCandidate(track: am("ep", album: "Word Up!: The Remixes - EP"), confidence: 100, reason: .isrc)
        let without = VersionPickerModel(target: target(.notThere, candidates: [ep]), search: FixedSearch([]), preferences: .standard)
        await without.load()
        #expect(without.selected?.track.id == "ep")
    }

    @Test("Use is offered for anything but the person's own pick; keeping Antiphon's version is a choice too")
    func canUse() async {
        let hits = am("i.hits", album: "Greatest Hits, Vol. 1")
        let theirs = VersionPickerModel(target: target(.antiphonsPick(hits)), search: FixedSearch([]), preferences: .standard)
        await theirs.load()
        #expect(theirs.canUse)

        let mine = VersionPickerModel(target: target(.yourPick(hits)), search: FixedSearch([am("ep", album: "EP")]), preferences: .standard)
        await mine.load()
        #expect(!mine.canUse)
        mine.selected = mine.versions.first { $0.track.id == "ep" }
        #expect(mine.canUse)
    }

    @Test("The sheet says which seam and playlist the version is for")
    func seamHeader() {
        #expect(PickCopy.seamTitle(target(.notThere)) == "For Remixes")
        #expect(PickCopy.seamDetail(target(.notThere)) == "Goes into Remixes AM on Apple Music")
    }

    @Test("Two ways: the version goes to the side the song didn't come from")
    func twoWayTarget() {
        var both = seam
        both = SeamSummary(id: both.id, spotify: both.spotify, appleMusic: both.appleMusic, direction: .bidirectional,
                           isMonitored: true, isPaused: false, monitorIntervalMinutes: 15, lastCheckedAt: nil, lastResult: nil,
                           counts: both.counts)
        let fromApple = CatalogTrack(platform: .appleMusic, id: "i.1", title: "Holocene", artist: "Bon Iver")
        let pick = PickTarget(seam: both, source: fromApple, current: .notThere)
        #expect(pick.target == .spotify)
        #expect(PickCopy.seamDetail(pick) == "Goes into Remixes on Spotify")
    }

    @Test("What the other playlist holds now, in words")
    func status() {
        let hits = am("i.hits", album: "Greatest Hits, Vol. 1")
        #expect(PickCopy.status(target(.antiphonsPick(hits))) == "Antiphon's pick: Word Up!, Greatest Hits, Vol. 1")
        #expect(PickCopy.status(target(.yourPick(hits))) == "Your pick: Word Up!, Greatest Hits, Vol. 1")
        #expect(PickCopy.status(target(.notThere)) == "Not in Remixes AM yet")
    }

    // MARK: - In a preview

    private func add(_ id: String, _ title: String, confidence: Int, album: String) -> SyncPlan.Add {
        let source = CatalogTrack(platform: .spotify, id: "spotify:track:\(id)", title: title, artist: "Korn")
        return SyncPlan.Add(source: source, match: MatchCandidate(track: am("am-\(id)", title, album: album), confidence: confidence,
                                                                  reason: .titleArtistDuration), alternatives: [])
    }

    private func plan(automatic: [SyncPlan.Add] = [], review: [SyncPlan.Add] = [], unavailable: [SyncPlan.Unavailable] = []) -> SyncPlan {
        SyncPlan(pairId: UUID(), createdAt: .now,
                 sides: [.appleMusic: SyncPlan.Side(platform: .appleMusic, automaticAdds: automatic, reviewAdds: review, unavailable: unavailable)],
                 conflicts: [], inSyncCount: 0)
    }

    @Test("A pick in a preview replaces Antiphon's choice where it was, as the person's pick")
    func choosingInPlace() {
        let first = add("1", "Freak on a Leash", confidence: 100, album: "Follow the Leader")
        let wordUp = add("2", "Word Up!", confidence: 100, album: "Greatest Hits, Vol. 1")
        let last = add("3", "Falling Away from Me", confidence: 100, album: "Issues")
        let ep = am("ep", album: "Word Up!: The Remixes - EP")

        let chosen = plan(automatic: [first, wordUp, last]).choosing(ep, for: wordUp.source)

        #expect(chosen.side(.appleMusic).automaticAdds.map(\.match.track.id) == ["am-1", "ep", "am-3"])
        #expect(chosen.side(.appleMusic).automaticAdds[1].match == MatchCandidate(track: ep, confidence: 100, reason: .manual))
    }

    @Test("A pick for a close match or a song that wasn't found makes it an add")
    func choosingMovesToAdds() {
        let close = add("1", "Word Up!", confidence: 86, album: "Pure... Rock")
        let missing = SyncPlan.Unavailable(source: CatalogTrack(platform: .spotify, id: "spotify:track:9", title: "Y'All Want a Single",
                                                                artist: "Korn"), alternatives: [])
        let ep = am("ep", album: "Word Up!: The Remixes - EP")
        let single = am("single", "Y'All Want a Single", album: "Take a Look in the Mirror")

        let chosen = plan(review: [close], unavailable: [missing]).choosing(ep, for: close.source).choosing(single, for: missing.source)

        let side = chosen.side(.appleMusic)
        #expect(side.reviewAdds.isEmpty)
        #expect(side.unavailable.isEmpty)
        #expect(side.automaticAdds.map(\.match.track.id) == ["ep", "single"])
        #expect(chosen.decisions()[TrackKey(close.source)] == .add(MatchCandidate(track: ep, confidence: 100, reason: .manual)))
    }

    @Test("Each version says its album, year and kind")
    func versionDetail() {
        var track = am("ep", album: "Word Up!: The Remixes - EP")
        track.releaseYear = 2004
        track.albumKind = .single
        #expect(PickCopy.versionDetail(track) == "Word Up!: The Remixes - EP · 2004 · single · 2:52")
    }
}
