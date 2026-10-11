import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Antiphon

/// Records edits and keeps each platform's playlist like the real one would:
/// adds append, removals remove, reorders rewrite.
final class FakeEditor: PlaylistEditor, Sendable {
    struct Edit: Equatable {
        let kind: String
        let platform: Platform
        let playlistId: String
        let trackIds: [String]
    }

    private let log = Mutex<[Edit]>([])
    private let live: Mutex<[Platform: [CatalogTrack]]>
    private let failing: Bool
    /// Apple Music answers with catalog IDs, not the IDs Antiphon asked with.
    private let renameLanded: Bool

    init(live: [Platform: [CatalogTrack]] = [:], failing: Bool = false, renameLanded: Bool = false) {
        self.live = Mutex(live)
        self.failing = failing
        self.renameLanded = renameLanded
    }

    var edits: [Edit] { log.withLock { $0 } }

    func add(_ tracks: [CatalogTrack], to playlistId: String, on platform: Platform) async throws -> [CatalogTrack] {
        if failing { throw URLError(.notConnectedToInternet) }
        log.withLock { $0.append(Edit(kind: "add", platform: platform, playlistId: playlistId, trackIds: tracks.map(\.id))) }
        let landed = renameLanded ? tracks.map { var t = $0; t.id = "catalog-\($0.title)"; return t } : tracks
        live.withLock { $0[platform, default: []] += landed }
        return landed
    }

    func remove(_ tracks: [CatalogTrack], from playlistId: String, on platform: Platform) async throws {
        if failing { throw URLError(.notConnectedToInternet) }
        log.withLock { $0.append(Edit(kind: "remove", platform: platform, playlistId: playlistId, trackIds: tracks.map(\.id))) }
        let ids = Set(tracks.map(\.id))
        live.withLock { $0[platform]?.removeAll { ids.contains($0.id) } }
    }

    func tracks(in playlistId: String, on platform: Platform) async throws -> [CatalogTrack] {
        live.withLock { $0[platform] ?? [] }
    }

    func reorder(_ playlistId: String, on platform: Platform, to order: [String]) async throws {
        log.withLock { $0.append(Edit(kind: "reorder", platform: platform, playlistId: playlistId, trackIds: order)) }
        live.withLock { state in
            var pool = state[platform] ?? []
            var ordered: [CatalogTrack] = []
            for id in order {
                if let index = pool.firstIndex(where: { $0.id == id }) { ordered.append(pool.remove(at: index)) }
            }
            state[platform] = ordered + pool
        }
    }
}

@Suite("Operation runner", .serialized)
struct OperationRunnerTests {

    // MARK: - Fixtures

    private struct Fixture {
        let container: ModelContainer
        let pairId: UUID
    }

    /// Garden Sundays, two-way. Holocene (row 1) was removed on Apple Music.
    private func makeFixture(direction: SyncDirection = .bidirectional) throws -> Fixture {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Garden Sundays",
                            appleMusicPlaylistId: "p.am", appleMusicPlaylistName: "Garden Sundays",
                            syncDirection: direction)
        context.insert(pair)
        let holocene = CachedTrack(isrc: "USJAG1100017", title: "Holocene", artist: "Bon Iver",
                                   spotifyTrackUri: "spotify:track:holo", appleMusicTrackId: "i.holo",
                                   source: .spotify, syncState: .synced)
        holocene.removalFlag = .removedFromAppleMusic
        holocene.syncPair = pair
        context.insert(holocene)
        try context.save()
        return Fixture(container: container, pairId: pair.id)
    }

    private func holoConflict() -> SyncPlan.Conflict {
        let spotify = CatalogTrack(platform: .spotify, id: "spotify:track:holo", title: "Holocene", artist: "Bon Iver", isrc: "USJAG1100017")
        var apple = spotify
        apple.platform = .appleMusic
        apple.id = "i.holo"
        return SyncPlan.Conflict(key: TrackKey(spotify), track: spotify, removedFrom: .appleMusic, noticedAt: nil, remaining: spotify, removed: apple)
    }

    private func rows(_ f: Fixture) throws -> [CachedTrack] {
        try ModelContext(f.container).fetch(FetchDescriptor<CachedTrack>())
    }

    private func logs(_ f: Fixture) throws -> [SyncLog] {
        try ModelContext(f.container).fetch(FetchDescriptor<SyncLog>(sortBy: [SortDescriptor(\.timestamp)]))
    }

    // MARK: - Conflicts

    @Test("Restoring puts the track back and logs a conflict run")
    func restore() async throws {
        let f = try makeFixture()
        let editor = FakeEditor()
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        let resolution = ConflictResolver.resolve(holoConflict(), as: .restore, appleMusicCanRemove: false)
        let outcome = try await runner.resolve([resolution], pairId: f.pairId)

        #expect(editor.edits == [.init(kind: "add", platform: .appleMusic, playlistId: "p.am", trackIds: ["i.holo"])])
        #expect(outcome.landed.count == 1)
        let row = try #require(try rows(f).first)
        #expect(row.removalFlag == nil)
        #expect(row.source == .both)
        let log = try #require(try logs(f).last)
        #expect(log.trigger == .conflict)
        #expect(log.changes.map(\.kind) == [.add])
    }

    @Test("Restoring updates the row even when Apple Music reports a different ID")
    func restoreWithNewID() async throws {
        let f = try makeFixture()
        let runner = OperationRunner(modelContainer: f.container, editor: FakeEditor(renameLanded: true), capabilities: .spotifyOnly)
        _ = try await runner.resolve([ConflictResolver.resolve(holoConflict(), as: .restore, appleMusicCanRemove: false)], pairId: f.pairId)
        let row = try #require(try rows(f).first)
        #expect(row.removalFlag == nil, "the question is answered")
        #expect(row.appleMusicTrackId == "catalog-Holocene")
        #expect(row.lastSyncAttempt != nil, "the write time lets the next sync wait for Apple Music to list it")
    }

    @Test("A track put back goes where it is on the other side")
    func restorePlacesTrack() async throws {
        let f = try makeFixture()
        let context = ModelContext(f.container)
        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)
        pair.appleMusicCreatedByAntiphon = true
        for (n, title) in ["Towers", "Calgary"].enumerated() {
            let row = CachedTrack(isrc: "R\(n)", title: title, artist: "Bon Iver", spotifyTrackUri: "spotify:track:\(title)",
                                  appleMusicTrackId: "i.\(title)", source: .both, syncState: .synced)
            row.syncPair = pair
            context.insert(row)
        }
        try context.save()
        func track(_ platform: Platform, _ id: String, _ title: String) -> CatalogTrack {
            CatalogTrack(platform: platform, id: id, title: title, artist: "Bon Iver")
        }
        // Holocene is first on Spotify; Apple Music lost it.
        let editor = FakeEditor(live: [
            .spotify: [track(.spotify, "spotify:track:holo", "Holocene"), track(.spotify, "spotify:track:Towers", "Towers"),
                       track(.spotify, "spotify:track:Calgary", "Calgary")],
            .appleMusic: [track(.appleMusic, "i.Towers", "Towers"), track(.appleMusic, "i.Calgary", "Calgary")]
        ])
        let runner = OperationRunner(modelContainer: f.container, editor: editor)
        _ = try await runner.resolve([ConflictResolver.resolve(holoConflict(), as: .restore, appleMusicCanRemove: true)], pairId: f.pairId)

        #expect(editor.edits.last == .init(kind: "reorder", platform: .appleMusic, playlistId: "p.am",
                                           trackIds: ["i.holo", "i.Towers", "i.Calgary"]))
        #expect(try await editor.tracks(in: "p.am", on: .appleMusic).map(\.title) == ["Holocene", "Towers", "Calgary"])
    }

    @Test("Apple Music playlists the person made keep added tracks at the end")
    func restoreAppendsOnPersonsPlaylist() async throws {
        let f = try makeFixture()
        let editor = FakeEditor(live: [.spotify: [CatalogTrack(platform: .spotify, id: "spotify:track:holo", title: "Holocene", artist: "Bon Iver")]])
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)
        _ = try await runner.resolve([ConflictResolver.resolve(holoConflict(), as: .restore, appleMusicCanRemove: false)], pairId: f.pairId)
        #expect(!editor.edits.contains { $0.kind == "reorder" })
    }

    @Test("Removing on the other side removes it on Spotify and forgets the row")
    func removeOnSpotify() async throws {
        let f = try makeFixture()
        let editor = FakeEditor()
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        let resolution = ConflictResolver.resolve(holoConflict(), as: .removeOnOtherSide, appleMusicCanRemove: false)
        _ = try await runner.resolve([resolution], pairId: f.pairId)

        #expect(editor.edits == [.init(kind: "remove", platform: .spotify, playlistId: "sp", trackIds: ["spotify:track:holo"])])
        #expect(try rows(f).isEmpty)
        #expect(try logs(f).last?.changes.map(\.kind) == [.remove])
        #expect(try logs(f).last?.tracksRemoved == 1)
    }

    @Test("Keeping the difference writes nothing and stops the question")
    func keepDifference() async throws {
        let f = try makeFixture()
        let editor = FakeEditor()
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        let resolution = ConflictResolver.resolve(holoConflict(), as: .keepDifference, appleMusicCanRemove: false)
        _ = try await runner.resolve([resolution], pairId: f.pairId)

        #expect(editor.edits.isEmpty)
        #expect(try rows(f).first?.removalKeptAt != nil)
        #expect(try logs(f).isEmpty, "nothing changed, so there's no run to log")
    }

    @Test("A failed write changes nothing locally")
    func failedWrite() async throws {
        let f = try makeFixture()
        let runner = OperationRunner(modelContainer: f.container, editor: FakeEditor(failing: true), capabilities: .spotifyOnly)
        let resolution = ConflictResolver.resolve(holoConflict(), as: .restore, appleMusicCanRemove: false)

        await #expect(throws: (any Error).self) { try await runner.resolve([resolution], pairId: f.pairId) }
        #expect(try rows(f).first?.removalFlag == .removedFromAppleMusic)
        #expect(try logs(f).isEmpty)
    }

    // MARK: - Undo

    /// A monitoring run that added two tracks to Spotify.
    private func seedRun(_ f: Fixture, platform: Platform = .spotify) throws -> UUID {
        let context = ModelContext(f.container)
        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)
        let log = SyncLog(action: .monitorSync, tracksAdded: 2)
        log.trigger = .monitor
        log.syncPair = pair
        context.insert(log)
        for n in 1...2 {
            let id = platform == .spotify ? "spotify:track:n\(n)" : "i.n\(n)"
            let change = SyncChange(platform: platform, kind: .add,
                                    track: CatalogTrack(platform: platform, id: id, title: "New \(n)", artist: "A"))
            change.sequence = n
            change.run = log
            context.insert(change)
            let row = CachedTrack(isrc: "N\(n)", title: "New \(n)", artist: "A",
                                  spotifyTrackUri: platform == .spotify ? id : nil,
                                  appleMusicTrackId: platform == .appleMusic ? id : "i.src\(n)",
                                  source: .both, syncState: .synced)
            row.syncPair = pair
            context.insert(row)
        }
        try context.save()
        return log.id
    }

    @Test("Undo removes what the run added and marks the run undone")
    func undoAdds() async throws {
        let f = try makeFixture()
        let runId = try seedRun(f)
        let live = (1...2).map { CatalogTrack(platform: .spotify, id: "spotify:track:n\($0)", title: "New \($0)", artist: "A") }
        let editor = FakeEditor(live: [.spotify: live])
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        let preview = try await runner.undoPreview(runId: runId)
        #expect(preview.summary == "Removes these 2 tracks from Spotify.")

        _ = try await runner.undo(runId: runId)

        #expect(editor.edits == [.init(kind: "remove", platform: .spotify, playlistId: "sp", trackIds: ["spotify:track:n2", "spotify:track:n1"])])
        let allLogs = try logs(f)
        let original = try #require(allLogs.first { $0.id == runId })
        #expect(original.undoneAt != nil)
        let undoRun = try #require(allLogs.first { $0.undoOfRunId == runId })
        #expect(undoRun.trigger == .undo)
        #expect(undoRun.changes.count == 2)

        // The undone tracks aren't added back by the next sync or asked about.
        let undoneRows = try rows(f).filter { $0.title.hasPrefix("New") }
        #expect(undoneRows.allSatisfy { $0.removalFlag == .removedFromSpotify && $0.removalKeptAt != nil })
    }

    @Test("Undo leaves Apple Music changes to the person when Apple Music can't remove")
    func undoGuided() async throws {
        let f = try makeFixture()
        let runId = try seedRun(f, platform: .appleMusic)
        let live = (1...2).map { CatalogTrack(platform: .appleMusic, id: "i.n\($0)", title: "New \($0)", artist: "A") }
        let editor = FakeEditor(live: [.appleMusic: live])
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        let outcome = try await runner.undo(runId: runId)
        #expect(editor.edits.isEmpty)
        #expect(outcome.guided.count == 2)
        #expect(try logs(f).first { $0.id == runId }?.undoneAt == nil, "nothing was undone yet")
    }

    @Test("Undo removes Apple Music adds directly when Antiphon created that playlist")
    func undoAppleMusicOwnPlaylist() async throws {
        let f = try makeFixture()
        let context = ModelContext(f.container)
        try #require(try context.fetch(FetchDescriptor<SyncPair>()).first).appleMusicCreatedByAntiphon = true
        try context.save()
        let runId = try seedRun(f, platform: .appleMusic)
        let live = (1...2).map { CatalogTrack(platform: .appleMusic, id: "i.n\($0)", title: "New \($0)", artist: "A") }
        let editor = FakeEditor(live: [.appleMusic: live])
        let runner = OperationRunner(modelContainer: f.container, editor: editor)

        let outcome = try await runner.undo(runId: runId)
        #expect(outcome.guided.isEmpty)
        #expect(editor.edits == [.init(kind: "remove", platform: .appleMusic, playlistId: "p.am", trackIds: ["i.n2", "i.n1"])])
    }

    @Test("A run can only be undone once")
    func undoOnce() async throws {
        let f = try makeFixture()
        let runId = try seedRun(f)
        let live = (1...2).map { CatalogTrack(platform: .spotify, id: "spotify:track:n\($0)", title: "New \($0)", artist: "A") }
        let runner = OperationRunner(modelContainer: f.container, editor: FakeEditor(live: [.spotify: live]), capabilities: .spotifyOnly)
        _ = try await runner.undo(runId: runId)
        await #expect(throws: OperationRunner.Failure.alreadyUndone) { try await runner.undo(runId: runId) }
    }

    // MARK: - Review decisions

    private func seedReview(_ f: Fixture) throws -> CatalogTrack {
        let context = ModelContext(f.container)
        let pair = try #require(try context.fetch(FetchDescriptor<SyncPair>()).first)
        let candidate = CatalogTrack(platform: .appleMusic, id: "1440", title: "Midnight City (Remaster)", artist: "M83", isrc: "FR6V81800112")
        let row = CachedTrack(isrc: "FR6V81100040", title: "Midnight City", artist: "M83",
                              spotifyTrackUri: "spotify:track:mc", source: .spotify, syncState: .needsReview)
        row.candidates = [MatchCandidate(track: candidate, confidence: 86, reason: .versionDifference)]
        row.syncPair = pair
        context.insert(row)
        try context.save()
        return candidate
    }

    @Test("Accepting a close match adds it and records the evidence")
    func acceptReview() async throws {
        let f = try makeFixture()
        let candidate = try seedReview(f)
        let editor = FakeEditor()
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        let key = TrackKey(platform: .spotify, id: "spotify:track:mc")
        _ = try await runner.decide(.accept(MatchCandidate(track: candidate, confidence: 86, reason: .versionDifference)), for: key, pairId: f.pairId)

        #expect(editor.edits == [.init(kind: "add", platform: .appleMusic, playlistId: "p.am", trackIds: ["1440"])])
        let row = try #require(try rows(f).first { $0.title == "Midnight City" })
        #expect(row.effectiveSyncState == .synced)
        #expect(row.appleMusicTrackId == "1440")
        #expect(row.matchConfidence == 86)
        #expect(row.counterpartISRC == "FR6V81800112")
        #expect(try logs(f).last?.trigger == .review)
    }

    @Test("Skipping a close match writes nothing and leaves the queue")
    func skipReview() async throws {
        let f = try makeFixture()
        _ = try seedReview(f)
        let editor = FakeEditor()
        let runner = OperationRunner(modelContainer: f.container, editor: editor, capabilities: .spotifyOnly)

        _ = try await runner.decide(.skip, for: TrackKey(platform: .spotify, id: "spotify:track:mc"), pairId: f.pairId)

        #expect(editor.edits.isEmpty)
        let row = try #require(try rows(f).first { $0.title == "Midnight City" })
        #expect(row.effectiveSyncState == .skipped)
    }
}
