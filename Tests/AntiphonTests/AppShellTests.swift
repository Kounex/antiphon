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
        #expect(summary.seamId == runClub.id, "tapping it reopens this seam's live sheet")
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
        #expect(summary.seamId == nil, "several: tapping lists them")
    }

    @Test("Several syncs: the list a tap opens, one row per seam with its own progress")
    func severalRows() {
        let a = seam("Run Club", .spotifyToApple)
        let b = seam("Late Night Drive", .spotifyToApple)
        let rows = RunningSyncSummary.rows(
            progress: [
                a.id: SyncProgress(totalTracks: 19, completedTracks: 4, failedTracks: 1),
                b.id: SyncProgress(totalTracks: 25, completedTracks: 2, failedTracks: 0, phase: .adding(platformName: "Apple Music"))
            ],
            seams: [a, b]
        )
        #expect(rows.map(\.title) == ["Late Night Drive", "Run Club"])
        #expect(rows.map(\.detail) == ["Adding 2 of 25 to Apple Music", "5 of 19 · Spotify → Apple Music"])
        #expect(rows.map(\.seamId) == [b.id, a.id])
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
                                  reviews: repository, problems: repository, catalogSearch: PreviewCatalogSearchService(),
                                  index: repository, availability: PreviewAvailabilityService(),
                                  activity: repository, settings: repository,
                                  appleMusicAccount: PreviewAppleMusicAccountReader())
        await model.refresh()
        #expect(model.reviewCount == 5)
    }

    @MainActor
    private func shellModel(_ seams: [SeamSummary] = []) -> AppShellModel {
        let repository = PreviewSeamRepository(seams: seams)
        return AppShellModel(seams: repository, accounts: PreviewAccounts(), sync: PreviewSyncService(), library: PreviewLibraryService(),
                             reviews: repository, problems: repository, catalogSearch: PreviewCatalogSearchService(),
                             index: repository, availability: PreviewAvailabilityService(),
                             activity: repository, settings: repository,
                             appleMusicAccount: PreviewAppleMusicAccountReader())
    }

    @Test("Sync now caches the flow, so reopening the same seam hands back the same model")
    @MainActor
    func makeSyncFlowCaches() {
        let model = shellModel()
        let id = UUID()
        let first = model.makeSyncFlow(seamId: id)
        #expect(model.makeSyncFlow(seamId: id) !== first, "a fresh 'Sync now' always starts over")
        let kept = model.makeSyncFlow(seamId: id)
        kept.debugStart()
        model.openSyncFlow(seamId: id)
        #expect(model.syncFlowModels[id] === kept, "already running: reuse it rather than restart it")
    }

    @Test("Opening a running sync from the accessory follows it without restarting its preview")
    @MainActor
    func reopenRunningSyncsFollowsUnknownIds() {
        let model = shellModel()
        let id = UUID()
        model.reopenRunningSyncs(ids: [id], focus: id)
        #expect(model.showsSyncSheet)
        #expect(model.focusedSyncSeamId == id)
        guard case .syncing = model.syncFlowModels[id]?.phase else {
            Issue.record("expected a model that follows the running sync")
            return
        }
    }

    @Test("Several running: the carousel orders them by seam name, like the accessory's own list")
    @MainActor
    func orderedSyncFlowSeamIds() async {
        let a = seam("Zebra Mix", .spotifyToApple)
        let b = seam("Ambient Focus", .spotifyToApple)
        let model = shellModel([a, b])
        await model.refresh()
        model.reopenRunningSyncs(ids: [a.id, b.id], focus: nil)
        #expect(model.orderedSyncFlowSeamIds == [b.id, a.id])
        #expect(model.focusedSyncSeamId == b.id, "no explicit focus: the first in that order")
    }

    @Test("Hiding keeps a running or finished flow, but drops an abandoned preview")
    @MainActor
    func hideSyncSheetKeepsOnlyLiveFlows() {
        let model = shellModel()
        let running = UUID()
        let abandoned = UUID()
        model.makeSyncFlow(seamId: running).debugStart()
        model.makeSyncFlow(seamId: abandoned) // still just a preview
        model.showsSyncSheet = true

        model.hideSyncSheet()

        #expect(!model.showsSyncSheet)
        #expect(model.syncFlowModels[running] != nil, "still running: kept, so reopening shows the same thing")
        #expect(model.syncFlowModels[abandoned] == nil, "never started: nothing to keep")
    }

    @Test("Closing one seam's flow moves focus to another still open, or closes the sheet if none are left")
    @MainActor
    func closeSyncFlowMovesFocusOrCloses() {
        let model = shellModel()
        let a = UUID()
        let b = UUID()
        model.reopenRunningSyncs(ids: [a, b], focus: a)

        model.closeSyncFlow(seamId: a)
        #expect(model.showsSyncSheet, "one flow is still open")
        #expect(model.focusedSyncSeamId == b)

        model.closeSyncFlow(seamId: b)
        #expect(!model.showsSyncSheet, "nothing left to show")
    }

    @Test("A widget link opens its seam, or New tracks, over whatever was open")
    @MainActor
    func widgetLinks() {
        let repository = PreviewSeamRepository(seams: [])
        let model = AppShellModel(seams: repository, accounts: PreviewAccounts(), sync: PreviewSyncService(), library: PreviewLibraryService(),
                                  reviews: repository, problems: repository, catalogSearch: PreviewCatalogSearchService(),
                                  index: repository, availability: PreviewAvailabilityService(),
                                  activity: repository, settings: repository,
                                  appleMusicAccount: PreviewAppleMusicAccountReader())
        let id = UUID()
        model.selectedTab = .library
        model.showsSettings = true
        model.open(.seam(id))
        #expect(model.selectedTab == .syncs)
        #expect(model.syncsPath == [.seam(id)])
        #expect(!model.showsSettings)

        model.open(.newTracks)
        #expect(model.selectedTab == .activity)
        #expect(model.activityModel.tab == .newTracks)
    }
}
