import Foundation
import Testing
@testable import Antiphon

@Suite("Undo")
struct UndoPlannerTests {

    private func am(_ n: Int) -> CatalogTrack {
        CatalogTrack(platform: .appleMusic, id: "i.\(n)", title: "Track \(n)", artist: "Artist")
    }

    private func sp(_ n: Int) -> CatalogTrack {
        CatalogTrack(platform: .spotify, id: "spotify:track:\(n)", title: "Track \(n)", artist: "Artist")
    }

    /// The storyboard's run: 4 added to Apple Music, 1 moved.
    private var storyboardRun: [RecordedChange] {
        (1...4).map { RecordedChange(kind: .add, platform: .appleMusic, track: am($0)) }
            + [RecordedChange(kind: .move, platform: .appleMusic, track: am(9), fromIndex: 2, toIndex: 7)]
    }

    @Test("Undo inverts each change: adds are removed, moves go back")
    func inverseOperations() {
        let undo = UndoPlanner.plan(for: storyboardRun, capabilities: .full)
        #expect(undo.operations.count == 5)
        #expect(undo.operations.filter { $0.kind == .remove }.map(\.track.id) == ["i.4", "i.3", "i.2", "i.1"])
        #expect(undo.operations.first == SyncOperation(kind: .move(from: 7, to: 2), platform: .appleMusic, track: am(9)))
    }

    @Test("Removed tracks are put back")
    func undoRemoval() {
        let undo = UndoPlanner.plan(for: [RecordedChange(kind: .remove, platform: .spotify, track: sp(1))], capabilities: .full)
        #expect(undo.operations == [SyncOperation(kind: .add, platform: .spotify, track: sp(1))])
        #expect(undo.summary == "Puts this track back on Spotify.")
    }

    @Test("The storyboard's undo states exactly what it reverts")
    func storyboardSummary() {
        let undo = UndoPlanner.plan(for: storyboardRun, capabilities: .full)
        #expect(undo.summary == "Removes these 4 tracks from Apple Music and puts the moved one back.")
        #expect(undo.guidedNote == nil)
    }

    @Test("When Apple Music can't remove, undo says what it can't revert")
    func guidedUndo() {
        let undo = UndoPlanner.plan(for: storyboardRun, capabilities: .spotifyOnly)
        #expect(undo.operations.isEmpty)
        #expect(undo.guided.count == 5)
        #expect(undo.summary == "Nothing can be undone automatically.")
        #expect(undo.guidedNote == "Antiphon can't change Apple Music playlists itself. It lists the 5 changes so you can revert them in the Music app.")
    }

    @Test("Mixed platforms: Spotify is undone, Apple Music is guided")
    func mixedUndo() {
        let changes = [
            RecordedChange(kind: .add, platform: .spotify, track: sp(1)),
            RecordedChange(kind: .add, platform: .spotify, track: sp(2)),
            RecordedChange(kind: .add, platform: .appleMusic, track: am(3))
        ]
        let undo = UndoPlanner.plan(for: changes, capabilities: .spotifyOnly)
        #expect(undo.summary == "Removes these 2 tracks from Spotify.")
        #expect(undo.guided.count == 1)
    }

    @Test("Changes that no longer apply are skipped and reported")
    func skipsStaleChanges() {
        let changes = [
            RecordedChange(kind: .add, platform: .spotify, track: sp(1)),
            RecordedChange(kind: .add, platform: .spotify, track: sp(2))
        ]
        // Track 2 was already removed by hand since the run.
        let undo = UndoPlanner.plan(for: changes, capabilities: .full, current: [.spotify: [sp(1)]])
        #expect(undo.operations.map(\.track.id) == ["spotify:track:1"])
        #expect(undo.skipped.map(\.track.id) == ["spotify:track:2"])
        #expect(undo.summary == "Removes this track from Spotify. 1 change no longer applies and is skipped.")
    }
}
