import Foundation
import Testing
@testable import Antiphon

@Suite("Track order")
struct TrackOrderTests {

    // MARK: - Where new tracks go

    @Test("A new track goes after the same neighbour it has on the other side")
    func afterNeighbour() {
        #expect(TrackOrder.desired(target: ["A", "C", "D", "B"], reference: ["A", "B", "C", "D"], placing: ["B"])
                == ["A", "B", "C", "D"])
    }

    @Test("A track first on the other side goes first")
    func atTheTop() {
        #expect(TrackOrder.desired(target: ["A", "B", "N"], reference: ["N", "A", "B"], placing: ["N"]) == ["N", "A", "B"])
    }

    @Test("Neighbours missing on this side are skipped")
    func skipsMissingNeighbours() {
        #expect(TrackOrder.desired(target: ["A", "B", "N"], reference: ["A", "X", "N", "B"], placing: ["N"]) == ["A", "N", "B"])
    }

    @Test("Tracks only on this side keep their place, and runs stay together")
    func extrasAndRuns() {
        #expect(TrackOrder.desired(target: ["E", "A", "B", "N1", "N2"], reference: ["A", "N1", "N2", "B"], placing: ["N1", "N2"])
                == ["E", "A", "N1", "N2", "B"])
    }

    @Test("Tracks not being placed never move")
    func othersStay() {
        // The person ordered this side differently: C, A, B keep that order,
        // and N follows C as it does on the other side.
        #expect(TrackOrder.desired(target: ["C", "A", "B", "N"], reference: ["A", "B", "C", "N"], placing: ["N"])
                == ["C", "N", "A", "B"])
    }

    // MARK: - Spotify moves

    @Test("Moves turn the current order into the desired one")
    func moves() {
        let moves = TrackOrder.moves(from: ["A", "B", "C", "N1", "N2"], to: ["A", "N1", "N2", "B", "C"])
        #expect(moves == [.init(rangeStart: 3, rangeLength: 2, insertBefore: 1)])
        #expect(TrackOrder.apply(moves, to: ["A", "B", "C", "N1", "N2"]) == ["A", "N1", "N2", "B", "C"])
        #expect(TrackOrder.moves(from: ["A", "B"], to: ["A", "B"]).isEmpty)
    }

    @Test("Several separate moves")
    func severalMoves() {
        let current = ["N0", "A", "B", "C", "N1", "N2"].shuffledLast()
        let desired = ["N0", "A", "N1", "B", "C", "N2"]
        let moves = TrackOrder.moves(from: current, to: desired)
        #expect(TrackOrder.apply(moves, to: current) == desired)
    }

    // MARK: - Apple Music entries

    @Test("Apple Music entries are put in the desired order, none dropped")
    func entryOrder() throws {
        let entries = [PlaylistEntryEdit.Entry(ids: ["e1", "i.a"], isrc: nil),
                       PlaylistEntryEdit.Entry(ids: ["e2", "i.b"], isrc: nil),
                       PlaylistEntryEdit.Entry(ids: ["e3", "i.n"], isrc: nil),
                       PlaylistEntryEdit.Entry(ids: ["e4", "i.x"], isrc: nil)]
        #expect(try PlaylistEntryEdit.orderedIndices(entries: entries, expectedCount: 4, desired: ["i.a", "i.n", "i.b"])
                == [0, 2, 1, 3])
        #expect(throws: PlaylistEntryEdit.Failure.incompleteRead(read: 4, expected: 5)) {
            try PlaylistEntryEdit.orderedIndices(entries: entries, expectedCount: 5, desired: ["i.a"])
        }
    }

    // MARK: - Setting

    @Test("Seams keep the source order by default; Apple Music playlists the person made only append")
    func placementSetting() {
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "A", appleMusicPlaylistId: "am",
                            appleMusicPlaylistName: "A", syncDirection: .bidirectional)
        #expect(pair.effectivePlacement == .sourceOrder)
        #expect(pair.canPlace(on: .spotify))
        #expect(!pair.canPlace(on: .appleMusic))
        pair.appleMusicCreatedByAntiphon = true
        #expect(pair.canPlace(on: .appleMusic))
        pair.newTrackPlacement = .end
        #expect(!pair.canPlace(on: .spotify))
    }
}

private extension Array where Element == String {
    /// The "N" tracks moved to the end, like an append leaves them.
    func shuffledLast() -> [String] { filter { !$0.hasPrefix("N") || $0 == "N0" } + filter { $0.hasPrefix("N") && $0 != "N0" } }
}

@Suite("Placing new tracks")
struct PlacementStepTests {
    private let rows = [
        PlacementStep.Row(key: "A", spotifyId: "spotify:track:a", appleMusicId: "i.a"),
        PlacementStep.Row(key: "B", spotifyId: "spotify:track:b", appleMusicId: "i.b"),
        PlacementStep.Row(key: "C", spotifyId: "spotify:track:c", appleMusicId: "i.c")
    ]

    @Test("Platform IDs map through Antiphon's rows to the other side's order")
    func mapsThroughRows() {
        let order = PlacementStep.desiredIDs(target: ["spotify:track:a", "spotify:track:c", "spotify:track:b"],
                                             reference: ["i.a", "i.b", "i.c"], rows: rows, placing: ["B"], on: .spotify)
        #expect(order == ["spotify:track:a", "spotify:track:b", "spotify:track:c"])
    }

    @Test("Nothing to write when the order is already right")
    func unchanged() {
        #expect(PlacementStep.desiredIDs(target: ["i.a", "i.b"], reference: ["spotify:track:a", "spotify:track:b"],
                                         rows: rows, placing: ["B"], on: .appleMusic) == nil)
    }

    @Test("Tracks Antiphon doesn't know and duplicates stay in place")
    func unknownsAndDuplicates() {
        let order = PlacementStep.desiredIDs(target: ["i.x", "i.a", "i.a", "i.c", "i.b"],
                                             reference: ["spotify:track:a", "spotify:track:b", "spotify:track:c"],
                                             rows: rows, placing: ["B"], on: .appleMusic)
        #expect(order == ["i.x", "i.a", "i.b", "i.a", "i.c"])
    }
}
