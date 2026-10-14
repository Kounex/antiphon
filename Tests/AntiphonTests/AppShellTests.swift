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

    @Test("Sync now opens the preview for that seam, and only that")
    @MainActor
    func syncNowOpensPreview() {
        let model = shellModel()
        let id = UUID()
        model.openSyncFlow(seamId: id)
        #expect(model.previewSeamId == id)
        #expect(!model.showsLiveSheet)
        #expect(model.syncFlowModels[id] != nil)
    }

    @Test("The bar above the tabs opens only the glass sheet, never the preview")
    @MainActor
    func barOpensOnlyLiveSheet() {
        let model = shellModel()
        let id = UUID()
        let flow = model.makeSyncFlow(seamId: id)
        flow.debugStart()

        model.reopenRunningSyncs(ids: [id], focus: id)

        #expect(model.showsLiveSheet)
        #expect(model.previewSeamId == nil, "the preview stays closed")
        #expect(model.focusedLiveSeamId == id)
        #expect(model.syncFlowModels[id] === flow, "the same flow, so the same tracklist")
    }

    @Test("Hide in the preview puts it away and keeps the running sync for the glass sheet")
    @MainActor
    func hidePreviewKeepsSync() {
        let model = shellModel()
        let id = UUID()
        model.openSyncFlow(seamId: id)
        model.syncFlowModels[id]?.debugStart()

        model.closePreview()

        #expect(model.previewSeamId == nil)
        #expect(model.syncFlowModels[id] != nil)
        #expect(model.liveSeamIds == [id])
    }

    @Test("Closing a preview that never started drops it")
    @MainActor
    func closeUnstartedPreview() {
        let model = shellModel()
        let id = UUID()
        model.openSyncFlow(seamId: id)
        model.closePreview()
        #expect(model.syncFlowModels[id] == nil)
    }

    @Test("Sync now on a seam that's syncing opens its glass sheet instead of restarting it")
    @MainActor
    func syncNowWhileSyncing() {
        let model = shellModel()
        let id = UUID()
        let flow = model.makeSyncFlow(seamId: id)
        flow.debugStart()
        model.openSyncFlow(seamId: id)
        #expect(model.syncFlowModels[id] === flow)
        #expect(model.showsLiveSheet)
        #expect(model.previewSeamId == nil)
    }

    @Test("Sync now after a sync finished (while hidden) starts a fresh preview, not the old result")
    @MainActor
    func syncNowAfterFinished() {
        let model = shellModel()
        let id = UUID()
        let finished = model.makeSyncFlow(seamId: id)
        finished.debugFinish(SyncResult(pairId: id, status: .success, tracksAdded: 3))
        model.openSyncFlow(seamId: id)
        #expect(model.syncFlowModels[id] !== finished)
        #expect(model.previewSeamId == id)
    }

    @Test("A sync the shell doesn't know yet (started in the background) is followed, not previewed")
    @MainActor
    func reopenFollowsUnknownIds() {
        let model = shellModel()
        let id = UUID()
        model.reopenRunningSyncs(ids: [id], focus: id)
        guard case .syncing = model.syncFlowModels[id]?.phase else {
            Issue.record("expected a model that follows the running sync")
            return
        }
    }

    @Test("The glass sheet lists running and finished syncs by seam name, not previews; unknown seams keep a stable order")
    @MainActor
    func liveSeamOrder() async {
        let a = seam("Zebra Mix", .spotifyToApple)
        let b = seam("Ambient Focus", .spotifyToApple)
        let model = shellModel([a, b])
        await model.refresh()
        let unknown = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        model.openSyncFlow(seamId: UUID())           // a preview: not in the glass sheet
        model.closePreview()
        model.makeSyncFlow(seamId: UUID())            // another preview left open elsewhere
        model.reopenRunningSyncs(ids: [a.id, b.id] + unknown, focus: nil)
        #expect(model.liveSeamIds == unknown + [b.id, a.id])
        #expect(model.focusedLiveSeamId == unknown.first)
    }

    @Test("Closing one seam's flow moves the glass sheet to another, or closes it when none are left")
    @MainActor
    func closeSyncFlowMovesFocusOrCloses() {
        let model = shellModel()
        let a = UUID(), b = UUID()
        model.reopenRunningSyncs(ids: [a, b], focus: a)

        model.closeSyncFlow(seamId: a)
        #expect(model.showsLiveSheet)
        #expect(model.focusedLiveSeamId == b)

        model.closeSyncFlow(seamId: b)
        #expect(!model.showsLiveSheet)
    }

    @Test("Review from a sync's result closes the sheets; other syncs stay for the bar")
    @MainActor
    func reviewFromSyncClosesSheets() {
        let model = shellModel()
        let done = UUID(), running = UUID()
        model.makeSyncFlow(seamId: done).debugFinish(SyncResult(pairId: done, status: .success, tracksAdded: 1))
        model.reopenRunningSyncs(ids: [running], focus: done)

        model.openReview(fromSyncOf: done)

        #expect(!model.showsLiveSheet && model.previewSeamId == nil, "a sheet can't present the review queue over it")
        #expect(model.syncFlowModels[running] != nil)
        #expect(model.syncFlowModels[done] == nil)
        #expect(model.reviewTarget == .init(seamId: done))
        #expect(model.syncsPath == [.seam(done)])
    }

    @Test("Removals to decide close the sheets, so their questions open now")
    @MainActor
    func conflictsCloseSheets() {
        let model = shellModel()
        let asking = UUID(), running = UUID()
        model.makeSyncFlow(seamId: asking)
        model.reopenRunningSyncs(ids: [running], focus: asking)

        model.askAboutRemovals(fromSyncOf: asking)

        #expect(!model.showsLiveSheet && model.previewSeamId == nil)
        #expect(model.pendingConflictSeam == asking)
        #expect(model.syncFlowModels[running] != nil)
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
