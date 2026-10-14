import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Choosing a version", .serialized)
struct ChooseVersionTests {

    private struct Fixture {
        let container: ModelContainer
        let pairId: UUID
        let key: TrackKey
    }

    private let ep = MatchCandidate(
        track: CatalogTrack(platform: .appleMusic, id: "ep", title: "Word Up!", artist: "Korn",
                            album: "Word Up!: The Remixes - EP", durationMs: 172_000, isrc: "USSM10411917"),
        confidence: 100, reason: .isrc)

    /// "Remixes", Spotify → Apple Music. Word Up! is synced as Antiphon's pick
    /// from Greatest Hits (`i.hits`), or isn't there yet.
    private func makeFixture(synced: Bool = true) throws -> Fixture {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Remixes",
                            appleMusicPlaylistId: "p.am", appleMusicPlaylistName: "Remixes", syncDirection: .spotifyToApple)
        context.insert(pair)
        let row = CachedTrack(isrc: "USSM10411917", title: "Word Up!", artist: "Korn",
                              spotifyTrackUri: "spotify:track:wordup", appleMusicTrackId: synced ? "i.hits" : nil,
                              source: synced ? .both : .spotify, syncState: synced ? .synced : .needsReview)
        row.counterpartISRC = synced ? "USSM10411917" : nil
        row.syncPair = pair
        context.insert(row)
        try context.save()
        return Fixture(container: container, pairId: pair.id, key: TrackKey(platform: .spotify, id: "spotify:track:wordup"))
    }

    private func runner(_ f: Fixture, _ editor: FakeEditor, ownPlaylist: Bool = false) -> OperationRunner {
        OperationRunner(modelContainer: f.container, editor: editor, capabilities: ownPlaylist ? .spotifyOnly : .full)
    }

    private func row(_ f: Fixture) throws -> CachedTrack {
        try #require(try ModelContext(f.container).fetch(FetchDescriptor<CachedTrack>()).first)
    }

    private func pins(_ f: Fixture) throws -> [TrackKey: CatalogTrack] {
        try #require(try ModelContext(f.container).fetch(FetchDescriptor<SyncPair>()).first).pinnedTracks
    }

    private func runs(_ f: Fixture) throws -> [SyncLog] {
        try ModelContext(f.container).fetch(FetchDescriptor<SyncLog>(sortBy: [SortDescriptor(\.timestamp)]))
    }

    private func live(_ ids: [String]) -> [Platform: [CatalogTrack]] {
        [.appleMusic: ids.map { CatalogTrack(platform: .appleMusic, id: $0, title: "Word Up!", artist: "Korn") }]
    }

    @Test("A synced song: the pick goes in, Antiphon's version comes out, in one run")
    func swapSynced() async throws {
        let f = try makeFixture()
        let editor = FakeEditor(live: live(["i.hits"]))

        let outcome = try await runner(f, editor).choose(ep, for: f.key, pairId: f.pairId)

        #expect(editor.edits.filter { $0.kind != "reorder" } == [
            .init(kind: "add", platform: .appleMusic, playlistId: "p.am", trackIds: ["ep"]),
            .init(kind: "remove", platform: .appleMusic, playlistId: "p.am", trackIds: ["i.hits"])
        ])
        #expect(outcome.guided.isEmpty)
        let row = try row(f)
        #expect(row.appleMusicTrackId == "ep")
        #expect(row.matchReason == .manual)
        #expect(row.matchConfidence == 100)
        #expect(try pins(f) == [f.key: ep.track])
        let run = try #require(try runs(f).last)
        #expect(run.trigger == .pick)
        #expect(run.changes.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.add, .remove])
    }

    @Test("The person's own Apple Music playlist: the pick goes in, removing the old one is up to them")
    func swapGuided() async throws {
        let f = try makeFixture()
        let editor = FakeEditor(live: live(["i.hits"]))

        let outcome = try await runner(f, editor, ownPlaylist: true).choose(ep, for: f.key, pairId: f.pairId)

        #expect(editor.edits.filter { $0.kind != "reorder" } == [.init(kind: "add", platform: .appleMusic, playlistId: "p.am", trackIds: ["ep"])])
        #expect(outcome.guided.map(\.track.id) == ["i.hits"])
        #expect(outcome.guided.allSatisfy { $0.isGuided })
        #expect(try row(f).appleMusicTrackId == "ep")
        #expect(try runs(f).last?.changes.map(\.kind) == [.add])
    }

    @Test("A song that isn't there yet is added now")
    func addUnsynced() async throws {
        let f = try makeFixture(synced: false)
        let editor = FakeEditor()

        _ = try await runner(f, editor).choose(ep, for: f.key, pairId: f.pairId)

        #expect(editor.edits.filter { $0.kind != "reorder" } == [.init(kind: "add", platform: .appleMusic, playlistId: "p.am", trackIds: ["ep"])])
        let row = try row(f)
        #expect(row.syncState == .synced)
        #expect(row.appleMusicTrackId == "ep")
        #expect(try pins(f) == [f.key: ep.track])
    }

    @Test("A song not stored yet (a first sync's preview): the pick is only kept")
    func keepWithoutRow() async throws {
        let f = try makeFixture()
        let editor = FakeEditor()
        let unknown = TrackKey(platform: .spotify, id: "spotify:track:new")

        _ = try await runner(f, editor).choose(ep, for: unknown, pairId: f.pairId)

        #expect(editor.edits.isEmpty)
        #expect(try pins(f)[unknown] == ep.track)
        #expect(try runs(f).isEmpty)
    }

    @Test("Picking the version already there only keeps it")
    func pickCurrent() async throws {
        let f = try makeFixture()
        let editor = FakeEditor(live: live(["i.hits"]))
        let current = MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "i.hits", title: "Word Up!", artist: "Korn"),
                                     confidence: 100, reason: .isrc)

        _ = try await runner(f, editor).choose(current, for: f.key, pairId: f.pairId)

        #expect(editor.edits.isEmpty)
        #expect(try pins(f)[f.key]?.id == "i.hits")
        #expect(try row(f).matchReason == .manual)
    }

    @Test("Keeping a pick from a preview writes nothing, even for a stored song")
    func keepOnly() async throws {
        let f = try makeFixture(synced: false)
        let editor = FakeEditor()

        try await runner(f, editor).keepPick(ep.track, for: f.key, pairId: f.pairId)

        #expect(editor.edits.isEmpty)
        #expect(try pins(f) == [f.key: ep.track])
        #expect(try row(f).syncState == .needsReview)
    }

    @Test("A second pick replaces the first")
    func repick() async throws {
        let f = try makeFixture(synced: false)
        let runner = runner(f, FakeEditor())
        try await runner.keepPick(ep.track, for: f.key, pairId: f.pairId)
        var other = ep.track
        other.id = "hits"
        try await runner.keepPick(other, for: f.key, pairId: f.pairId)
        #expect(try pins(f) == [f.key: other])
    }

    @Test("Undoing a swap puts Antiphon's version back and forgets the pick")
    func undoSwap() async throws {
        let f = try makeFixture()
        let editor = FakeEditor(live: live(["i.hits"]))
        let runner = runner(f, editor)
        let swap = try await runner.choose(ep, for: f.key, pairId: f.pairId)

        _ = try await runner.undo(runId: try #require(swap.runId))

        let row = try row(f)
        #expect(row.appleMusicTrackId == "i.hits")
        #expect(row.syncState == .synced)
        #expect(row.removalFlag == nil, "not a removal: the song is still in both playlists")
        #expect(row.matchReason != .manual)
        #expect(try pins(f).isEmpty)
    }

    @Test("Undoing a pick that added a song puts it back to waiting")
    func undoAdd() async throws {
        let f = try makeFixture(synced: false)
        let runner = runner(f, FakeEditor())
        let added = try await runner.choose(ep, for: f.key, pairId: f.pairId)

        _ = try await runner.undo(runId: try #require(added.runId))

        let row = try row(f)
        #expect(row.appleMusicTrackId == nil)
        #expect(row.syncState == .pending)
        #expect(row.removalFlag == nil)
        #expect(try pins(f).isEmpty)
    }

    @Test("Letting Antiphon choose again forgets the pick and changes nothing else")
    func forget() async throws {
        let f = try makeFixture()
        let editor = FakeEditor(live: live(["i.hits"]))
        let runner = runner(f, editor)
        _ = try await runner.choose(ep, for: f.key, pairId: f.pairId)
        let before = editor.edits.count

        try await runner.forgetPick(for: f.key, pairId: f.pairId)

        #expect(try pins(f).isEmpty)
        #expect(editor.edits.count == before)
        #expect(try row(f).appleMusicTrackId == "ep")
    }
}
