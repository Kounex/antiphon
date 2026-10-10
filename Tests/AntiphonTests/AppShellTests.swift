import Foundation
import Testing
@testable import Antiphon

@Suite("App shell")
struct AppShellTests {

    private func seam(_ name: String, _ direction: SyncDirection, review: Int = 0) -> SeamSummary {
        SeamSummary(
            id: UUID(),
            spotify: SeamSide(platform: .spotify, playlistId: "s", name: name, artworkURL: nil),
            appleMusic: SeamSide(platform: .appleMusic, playlistId: "a", name: name, artworkURL: nil),
            direction: direction, isMonitored: true, isPaused: false, monitorIntervalMinutes: 15,
            lastCheckedAt: nil, lastResult: nil,
            counts: SeamCounts(synced: 0, review: review, missing: 0, total: review)
        )
    }

    @Test("Direction reads as arrows for one way, words for both")
    func directionText() {
        #expect(seam("A", .spotifyToApple).directionText == "Spotify → Apple Music")
        #expect(seam("A", .appleToSpotify).directionText == "Apple Music → Spotify")
        #expect(seam("A", .bidirectional).directionText == "Both ways")
    }

    @Test("One running sync names the playlist and counts its tracks")
    func singleSync() throws {
        let runClub = seam("Run Club", .spotifyToApple)
        let summary = try #require(RunningSyncSummary.make(
            progress: [runClub.id: SyncProgress(totalTracks: 52, completedTracks: 30, failedTracks: 1)],
            seams: [runClub]
        ))
        #expect(summary.title == "Syncing Run Club")
        #expect(summary.detail == "31 of 52 · Spotify → Apple Music")
        #expect(summary.done == 31)
        #expect(summary.total == 52)
    }

    @Test("The write phase says where tracks are going")
    func addingPhase() throws {
        let runClub = seam("Run Club", .spotifyToApple)
        let summary = try #require(RunningSyncSummary.make(
            progress: [runClub.id: SyncProgress(totalTracks: 33, completedTracks: 5, failedTracks: 0, phase: .adding(platformName: "Apple Music"))],
            seams: [runClub]
        ))
        #expect(summary.detail == "Adding 5 of 33 to Apple Music")
    }

    @Test("Several syncs combine into one line")
    func severalSyncs() throws {
        let a = seam("Run Club", .spotifyToApple)
        let b = seam("Late Night Drive", .spotifyToApple)
        let c = seam("Garden Sundays", .bidirectional)
        let summary = try #require(RunningSyncSummary.make(
            progress: [
                a.id: SyncProgress(totalTracks: 52, completedTracks: 31, failedTracks: 0),
                b.id: SyncProgress(totalTracks: 10, completedTracks: 2, failedTracks: 0),
                c.id: SyncProgress(totalTracks: 0, completedTracks: 0, failedTracks: 0)
            ],
            seams: [a, b, c]
        ))
        #expect(summary.title == "Syncing 3 playlists")
        #expect(summary.detail == "33 of 62")
    }

    @Test("Nothing running, no accessory")
    func idle() {
        #expect(RunningSyncSummary.make(progress: [:], seams: []) == nil)
    }

    @Test("Avatar initials come from the Spotify display name")
    func initials() {
        #expect(AccountInitials.from("Maya Klein") == "MK")
        #expect(AccountInitials.from("maya") == "M")
        #expect(AccountInitials.from("  ") == nil)
        #expect(AccountInitials.from(nil) == nil)
    }

    @Test("The Syncs badge counts tracks waiting for review across seams")
    @MainActor
    func reviewBadge() async {
        let repository = PreviewSeamRepository(seams: [seam("A", .spotifyToApple, review: 3), seam("B", .bidirectional, review: 2)])
        let model = AppShellModel(seams: repository, accounts: PreviewAccounts(), sync: PreviewSyncService(), library: PreviewLibraryService(),
                                  reviews: repository, problems: repository, catalogSearch: PreviewCatalogSearchService())
        await model.refresh()
        #expect(model.reviewCount == 5)
    }
}
