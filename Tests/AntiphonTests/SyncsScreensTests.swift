import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Syncs screens")
@MainActor
struct SyncsScreensTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seam(
        _ name: String, _ direction: SyncDirection = .spotifyToApple,
        monitored: Bool = true, paused: Bool = false,
        synced: Int = 10, review: Int = 0, missing: Int = 0,
        checkedMinutesAgo: Double? = 4, result: SyncResultStatus? = .success
    ) -> SeamSummary {
        SeamSummary(
            id: UUID(),
            spotify: SeamSide(platform: .spotify, playlistId: "s-\(name)", name: name, artworkURL: nil),
            appleMusic: SeamSide(platform: .appleMusic, playlistId: "a-\(name)", name: name, artworkURL: nil),
            direction: direction, isMonitored: monitored, isPaused: paused, monitorIntervalMinutes: 15,
            lastCheckedAt: checkedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, lastResult: result,
            counts: SeamCounts(synced: synced, review: review, missing: missing, total: synced + review + missing)
        )
    }

    // MARK: - Relative time

    @Test("Freshness reads like a person would say it")
    func relativeTime() {
        #expect(RelativeTime.text(since: now.addingTimeInterval(-20), now: now) == "just now")
        #expect(RelativeTime.text(since: now.addingTimeInterval(-4 * 60), now: now) == "4 min ago")
        #expect(RelativeTime.text(since: now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(RelativeTime.text(since: now.addingTimeInterval(-2 * 86400), now: now) == "2 days ago")
        #expect(RelativeTime.text(since: now.addingTimeInterval(-86400), now: now) == "yesterday")
    }

    // MARK: - Home

    private func home(_ seams: [SeamSummary], spotifyConnected: Bool = true) async -> SyncsHomeModel {
        let accounts = PreviewAccounts()
        accounts.isSpotifyConnected = spotifyConnected
        let model = SyncsHomeModel(seams: PreviewSeamRepository(seams: seams), accounts: accounts, now: { self.now })
        await model.load()
        return model
    }

    @Test("Hero counts tracks in sync; the line under it counts watching seams")
    func hero() async {
        let model = await home([
            seam("Late Night Drive", synced: 48, review: 3, missing: 1),
            seam("Garden Sundays", .bidirectional, synced: 117, checkedMinutesAgo: 2),
            seam("Vinyl Rips", monitored: false, synced: 80)
        ])
        #expect(model.tracksInSync == 245)
        #expect(model.watchingCount == 2)
        #expect(model.heroDetail == "across 3 seams · checked 2 min ago")
    }

    @Test("Filter chips count and filter seams")
    func filters() async {
        let model = await home([
            seam("A", review: 2), seam("B"), seam("C", monitored: false, paused: true)
        ])
        #expect(model.chips.map(\.count) == [3, 2, 1, 1])
        model.filter = .needsReview
        #expect(model.visibleSeams.map(\.name) == ["A"])
        model.filter = .paused
        #expect(model.visibleSeams.map(\.name) == ["C"])
        model.filter = .watching
        #expect(model.visibleSeams.map(\.name) == ["A", "B"])
    }

    @Test("Review banner names the seams waiting for a call")
    func reviewBanner() async throws {
        let model = await home([seam("Late Night Drive", review: 3), seam("Run Club", review: 2), seam("Garden Sundays")])
        let banner = try #require(model.reviewBanner)
        #expect(banner.title == "5 tracks need your call")
        #expect(banner.message == "Close matches in Late Night Drive and Run Club. Nothing was added yet.")
    }

    @Test("No review, no banner")
    func noBanner() async {
        #expect(await home([seam("A")]).reviewBanner == nil)
    }

    @Test("Card subtitle: direction and freshness")
    func cardSubtitles() async {
        let model = await home([])
        #expect(model.subtitle(for: seam("A")) == "Spotify → Apple Music · checked 4 min ago")
        #expect(model.subtitle(for: seam("A", .bidirectional, checkedMinutesAgo: nil)) == "Both ways · not synced yet")
        #expect(model.subtitle(for: seam("A", paused: true)) == "Spotify → Apple Music · paused")
    }

    @Test("A failed seam or a signed-out Spotify shows on the card")
    func failures() async {
        let signedIn = await home([])
        #expect(signedIn.failure(for: seam("A", result: .failed)) == "Failed")
        #expect(signedIn.failure(for: seam("A")) == nil)
        let signedOut = await home([], spotifyConnected: false)
        #expect(signedOut.failure(for: seam("A")) == "Sign in")
    }

    // MARK: - Detail

    @Test("Detail chips and tiles count the seam's tracks")
    func detailChips() async throws {
        let s = seam("Late Night Drive", synced: 48, review: 3, missing: 1)
        let tracks = [
            PreviewFixtures.track("Nightcall", "Kavinsky", state: .synced, isNew: true),
            PreviewFixtures.track("Midnight City", "M83", state: .review(confidence: 86, reason: .versionDifference)),
            PreviewFixtures.track("Tokyo Drift", "Teriyaki Boyz", state: .missing("Not on Apple Music in Germany")),
            PreviewFixtures.track("Running Up That Hill", "Kate Bush", state: .synced)
        ]
        let model = SeamDetailModel(seamId: s.id, repository: StubDetailRepository(detail: SeamDetail(summary: s, tracks: tracks)))
        await model.load()
        #expect(model.chips.map(\.count) == [4, 1, 1, 1])
        model.filter = .toReview
        #expect(model.visibleTracks.map(\.title) == ["Midnight City"])
        model.filter = .new
        #expect(model.visibleTracks.map(\.title) == ["Nightcall"])
        model.filter = .missing
        #expect(model.visibleTracks.map(\.title) == ["Tokyo Drift"])
        #expect(model.tiles == SeamDetailModel.Tiles(inSync: 48, toReview: 3, unavailable: 1))
    }

    @Test("Detail header says how the seam is watched")
    func detailHeader() {
        #expect(SeamDetailModel.headerDetail(for: seam("A")) == "Spotify → Apple Music · watching about every 15 min")
        #expect(SeamDetailModel.headerDetail(for: seam("A", monitored: false)) == "Spotify → Apple Music · syncs when you ask")
        #expect(SeamDetailModel.headerDetail(for: seam("A", paused: true)) == "Spotify → Apple Music · paused")
    }

    // MARK: - Rules copy

    @Test("Direction consequence rewrites itself with the choice")
    func directionCopy() {
        #expect(RulesCopy.direction(.spotifyToApple) == "Tracks added on Spotify are added on Apple Music. Changes made on Apple Music stay there.")
        #expect(RulesCopy.direction(.appleToSpotify) == "Tracks added on Apple Music are added on Spotify. Changes made on Spotify stay there.")
        #expect(RulesCopy.direction(.bidirectional) == "Changes on either side are copied to the other. If a track is removed on one side, Antiphon asks before removing it on the other.")
    }

    @Test("Removal consequence names the platforms")
    func removalCopy() {
        #expect(RulesCopy.removal(.keep, direction: .spotifyToApple) == "Removing a track on Spotify won't touch Apple Music.")
        #expect(RulesCopy.removal(.mirror, direction: .spotifyToApple) == "Removing a track on Spotify removes it on Apple Music too. You can undo it from Activity.")
        #expect(RulesCopy.removal(.ask, direction: .bidirectional) == "If a track is removed on one side, Antiphon asks before touching the other.")
        #expect(RulesCopy.removal(.keep, direction: .bidirectional) == "A track removed on one side stays on the other.")
    }

    @Test("Monitoring copy is honest about timing")
    func monitoringCopy() {
        #expect(RulesCopy.monitoring(isOn: true, interval: 15, direction: .spotifyToApple) == "Checks Spotify about every 15 min and syncs new tracks. iOS decides the exact moment.")
        #expect(RulesCopy.monitoring(isOn: true, interval: 60, direction: .bidirectional) == "Checks both playlists about every hour and syncs new tracks. iOS decides the exact moment.")
        #expect(RulesCopy.monitoring(isOn: false, interval: 15, direction: .spotifyToApple) == "Antiphon only syncs when you ask.")
        #expect(RulesCopy.intervalLabel(720) == "Twice a day")
        #expect(RulesCopy.intervalLabel(1440) == "Daily")
    }

    // MARK: - Rules model

    @Test("Changing direction rebuilds the seam's alignment on the next sync")
    func directionChangeRebuilds() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "s", spotifyPlaylistName: "A", appleMusicPlaylistId: "a",
                            appleMusicPlaylistName: "A", syncDirection: .spotifyToApple)
        context.insert(pair)
        try context.save()
        let repository = SwiftDataSeamRepository(modelContainer: container)

        var rules = try #require(try await repository.rules(for: pair.id))
        rules.notifyNewTracks = true
        try await repository.update(rules, for: pair.id)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncPair>()).first?.needsRebuild == false)

        rules.direction = .bidirectional
        try await repository.update(rules, for: pair.id)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncPair>()).first?.needsRebuild == true)
    }

    @Test("Monitoring never syncs a paused seam")
    func pausedSkipped() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "s", spotifyPlaylistName: "A", appleMusicPlaylistId: "a",
                            appleMusicPlaylistName: "A", syncDirection: .spotifyToApple)
        pair.isMonitored = true
        pair.pausedAt = Date()
        context.insert(pair)
        try context.save()

        let engine = SyncEngine(modelContainer: container, spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        let results = await engine.syncAllMonitored()
        #expect(results.isEmpty)
    }
}

/// Returns one fixed detail.
actor StubDetailRepository: SeamRepository {
    let stored: SeamDetail
    init(detail: SeamDetail) { stored = detail }
    func seams() async throws -> [SeamSummary] { [stored.summary] }
    func detail(for id: UUID) async throws -> SeamDetail? { stored }
    func rules(for id: UUID) async throws -> SeamRules? { nil }
    func update(_ rules: SeamRules, for id: UUID) async throws {}
    func unlink(_ id: UUID) async throws {}
    func markViewed(_ id: UUID) async throws {}
}
