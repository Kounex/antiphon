import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Opening the version picker", .serialized)
struct PickTargetTests {

    private struct Fixture {
        let container: ModelContainer
        let pairId: UUID
        let rowId: UUID
        var repository: SwiftDataSeamRepository { SwiftDataSeamRepository(modelContainer: container) }
    }

    private func makeFixture(direction: SyncDirection = .spotifyToApple, synced: Bool = true,
                             configure: (CachedTrack, SyncPair, ModelContext) -> Void = { _, _, _ in }) throws -> Fixture {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Remixes",
                            appleMusicPlaylistId: "p.am", appleMusicPlaylistName: "Remixes AM", syncDirection: direction)
        context.insert(pair)
        let row = CachedTrack(isrc: "USSM10411917", title: "Word Up!", artist: "Korn", albumName: "Word Up! (The Remixes)",
                              durationMs: 172_000, spotifyTrackUri: "spotify:track:wordup", appleMusicTrackId: synced ? "i.hits" : nil,
                              source: synced ? .both : .spotify, syncState: synced ? .synced : .needsReview)
        row.counterpartISRC = synced ? "USSM10411917" : nil
        row.counterpartAlbum = synced ? "Greatest Hits, Vol. 1" : nil
        row.syncPair = pair
        context.insert(row)
        configure(row, pair, context)
        try context.save()
        return Fixture(container: container, pairId: pair.id, rowId: row.id)
    }

    @Test("A synced song opens on Antiphon's pick, with its album, for its seam")
    func synced() async throws {
        let f = try makeFixture()
        let target = try #require(try await f.repository.pickTarget(seamId: f.pairId, rowId: f.rowId))
        #expect(target.seam.name == "Remixes")
        #expect(target.source.id == "spotify:track:wordup")
        #expect(target.target == .appleMusic)
        #expect(target.current == .antiphonsPick(CatalogTrack(platform: .appleMusic, id: "i.hits", title: "Word Up!", artist: "Korn",
                                                              album: "Greatest Hits, Vol. 1", isrc: "USSM10411917")))
    }

    @Test("A song with a pick opens on the person's pick")
    func picked() async throws {
        let pick = CatalogTrack(platform: .appleMusic, id: "ep", title: "Word Up!", artist: "Korn", album: "Word Up!: The Remixes - EP")
        let f = try makeFixture { _, pair, context in
            let pin = PinnedMatch(key: TrackKey(platform: .spotify, id: "spotify:track:wordup"), track: pick)
            pin.syncPair = pair
            context.insert(pin)
        }
        let target = try #require(try await f.repository.pickTarget(seamId: f.pairId, rowId: f.rowId))
        #expect(target.current == .yourPick(pick))
    }

    @Test("A close match opens with the matcher's candidates and nothing there yet")
    func closeMatch() async throws {
        let candidate = MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "hits", title: "Word Up!", artist: "Korn"),
                                       confidence: 86, reason: .versionDifference)
        let f = try makeFixture(synced: false) { row, _, _ in row.candidates = [candidate] }
        let target = try #require(try await f.repository.pickTarget(seamId: f.pairId, rowId: f.rowId))
        #expect(target.current == .notThere)
        #expect(target.candidates == [candidate])
    }

    @Test("New tracks: the song is found by the version Antiphon added")
    func byAddedVersion() async throws {
        let f = try makeFixture()
        let byId = try await f.repository.pickTarget(seamId: f.pairId, added: TrackKey(platform: .appleMusic, id: "i.hits"), isrc: nil)
        #expect(byId?.source.id == "spotify:track:wordup")
        // Apple Music lists an add under another ID later; the ISRC still finds it.
        let byISRC = try await f.repository.pickTarget(seamId: f.pairId, added: TrackKey(platform: .appleMusic, id: "catalog-1"),
                                                       isrc: "USSM10411917")
        #expect(byISRC?.source.id == "spotify:track:wordup")
    }

    @Test("Two ways, the song came from Apple Music: the version goes to Spotify")
    func twoWayFromApple() async throws {
        let f = try makeFixture(direction: .bidirectional) { _, pair, context in
            let run = SyncLog(action: .manualSync, result: .success, tracksAdded: 1, tracksRemoved: 0)
            run.syncPair = pair
            context.insert(run)
            let change = SyncChange(platform: .spotify, kind: .add,
                                    track: CatalogTrack(platform: .spotify, id: "spotify:track:wordup", title: "Word Up!", artist: "Korn"))
            change.run = run
            context.insert(change)
        }
        let target = try #require(try await f.repository.pickTarget(seamId: f.pairId, rowId: f.rowId))
        #expect(target.source.platform == .appleMusic)
        #expect(target.target == .spotify)
    }

    @Test("The seam's track list says which songs have a pick")
    func listSaysPicked() async throws {
        let f = try makeFixture { _, pair, context in
            let pin = PinnedMatch(key: TrackKey(platform: .spotify, id: "spotify:track:wordup"),
                                  track: CatalogTrack(platform: .appleMusic, id: "ep", title: "Word Up!", artist: "Korn"))
            pin.syncPair = pair
            context.insert(pin)
        }
        let detail = try #require(try await f.repository.detail(for: f.pairId))
        #expect(detail.tracks.first?.isPicked == true)
        let first = try #require(detail.tracks.first)
        let line = await MainActor.run { SeamPresentation.trackDetail(first) }
        #expect(line == "Korn · your pick")
    }

    @Test("A picked song shows the picked version's cover in the seam's list")
    func listShowsPickedCover() async throws {
        let f = try makeFixture { _, pair, context in
            let pin = PinnedMatch(key: TrackKey(platform: .spotify, id: "spotify:track:wordup"),
                                  track: CatalogTrack(platform: .appleMusic, id: "ep", title: "Word Up!", artist: "Korn",
                                                      artworkURL: "https://example.com/remixes.jpg"))
            pin.syncPair = pair
            context.insert(pin)
        }
        let detail = try #require(try await f.repository.detail(for: f.pairId))
        #expect(detail.tracks.first?.artworkURL == URL(string: "https://example.com/remixes.jpg"))
    }

    @Test("Preview rows show the cover of the version that will be written, else the song's own")
    func previewCover() async {
        let source = CatalogTrack(platform: .spotify, id: "s", title: "Word Up!", artist: "Korn", artworkURL: "https://example.com/source.jpg")
        let pick = CatalogTrack(platform: .appleMusic, id: "ep", title: "Word Up!", artist: "Korn", artworkURL: "https://example.com/remixes.jpg")
        let library = CatalogTrack(platform: .appleMusic, id: "i.1", title: "Word Up!", artist: "Korn", artworkURL: "musicKit://artwork/1")
        await MainActor.run {
            #expect(SeamPresentation.cover(of: source, writing: pick) == URL(string: "https://example.com/remixes.jpg"))
            #expect(SeamPresentation.cover(of: source, writing: library) == URL(string: "https://example.com/source.jpg"))
            #expect(SeamPresentation.cover(of: source, writing: nil) == URL(string: "https://example.com/source.jpg"))
        }
    }
}
