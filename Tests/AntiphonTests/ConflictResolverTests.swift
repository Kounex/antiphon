import Foundation
import Testing
@testable import Antiphon

@Suite("Conflict resolution")
struct ConflictResolverTests {

    /// Holocene was removed from Garden Sundays on Apple Music; it's still on Spotify.
    private let holocene: SyncPlan.Conflict = {
        let spotify = CatalogTrack(platform: .spotify, id: "spotify:track:holo", title: "Holocene", artist: "Bon Iver", isrc: "USJAG1100017")
        var apple = spotify
        apple.platform = .appleMusic
        apple.id = "i.holo"
        return SyncPlan.Conflict(key: TrackKey(spotify), track: spotify, removedFrom: .appleMusic, noticedAt: nil, remaining: spotify, removed: apple)
    }()

    private let towers: SyncPlan.Conflict = {
        let apple = CatalogTrack(platform: .appleMusic, id: "i.towers", title: "Towers", artist: "Bon Iver")
        var spotify = apple
        spotify.platform = .spotify
        spotify.id = "spotify:track:towers"
        return SyncPlan.Conflict(key: TrackKey(apple), track: apple, removedFrom: .spotify, noticedAt: nil, remaining: apple, removed: spotify)
    }()

    @Test("Remove on the other side removes it from the playlist that still has it")
    func removeOnOtherSide() {
        let resolution = ConflictResolver.resolve(holocene, as: .removeOnOtherSide, appleMusicCanRemove: false)
        #expect(resolution.operations == [SyncOperation(kind: .remove, platform: .spotify, track: holocene.remaining!)])
        #expect(resolution.rowUpdate == .forget)
    }

    @Test("Removing on Apple Music is guided when Apple Music can't remove")
    func removeOnAppleMusicGuided() {
        let resolution = ConflictResolver.resolve(towers, as: .removeOnOtherSide, appleMusicCanRemove: false)
        #expect(resolution.operations.first?.platform == .appleMusic)
        #expect(resolution.operations.first?.isGuided == true)
        #expect(resolution.rowUpdate == .keepDifference, "until the person removes it, the difference stays")
    }

    @Test("Restore puts the track back where it was removed")
    func restore() {
        let resolution = ConflictResolver.resolve(holocene, as: .restore, appleMusicCanRemove: false)
        #expect(resolution.operations == [SyncOperation(kind: .add, platform: .appleMusic, track: holocene.removed!)])
        #expect(resolution.rowUpdate == .restore)
    }

    @Test("Keep the difference writes nothing and stops asking")
    func keepDifference() {
        let resolution = ConflictResolver.resolve(holocene, as: .keepDifference, appleMusicCanRemove: false)
        #expect(resolution.operations.isEmpty)
        #expect(resolution.rowUpdate == .keepDifference)
    }

    @Test("Doing the same for every conflict applies the choice to each one")
    func resolveAll() {
        let resolutions = ConflictResolver.resolveAll([holocene, towers], as: .restore, appleMusicCanRemove: true)
        #expect(resolutions.flatMap(\.operations).map(\.platform) == [.appleMusic, .spotify])
        #expect(resolutions.allSatisfy { $0.rowUpdate == .restore })
    }

    @Test("The button repeats the choice as a verb")
    func buttonTitles() {
        #expect(ConflictResolver.buttonTitle(for: holocene, outcome: .removeOnOtherSide) == "Remove from Spotify")
        #expect(ConflictResolver.buttonTitle(for: holocene, outcome: .restore) == "Put back on Apple Music")
        #expect(ConflictResolver.buttonTitle(for: holocene, outcome: .keepDifference) == "Keep the difference")
    }
}
