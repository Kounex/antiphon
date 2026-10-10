#if DEBUG
import Foundation

/// Synthetic data for SwiftUI previews and the DEBUG screenshot router.
/// Names follow the storyboard; nothing here is real user data.
enum PreviewFixtures {

    static let lateNightDrive = seam(
        "Late Night Drive", direction: .spotifyToApple, monitored: true,
        counts: SeamCounts(synced: 48, review: 3, missing: 1, total: 52), checkedMinutesAgo: 4
    )
    static let gardenSundays = seam(
        "Garden Sundays", direction: .bidirectional, monitored: true,
        counts: SeamCounts(synced: 117, review: 0, missing: 0, total: 117), checkedMinutesAgo: 30
    )
    static let runClub = seam(
        "Run Club", appleMusicName: "Running", direction: .spotifyToApple, monitored: true,
        counts: SeamCounts(synced: 31, review: 2, missing: 0, total: 52), checkedMinutesAgo: 1
    )
    static let vinylRips = seam(
        "Vinyl Rips", direction: .appleToSpotify, monitored: false, paused: true,
        counts: SeamCounts(synced: 80, review: 0, missing: 7, total: 87), checkedMinutesAgo: 60 * 26
    )

    static let seams = [lateNightDrive, gardenSundays, runClub, vinylRips]

    static let lateNightDriveTracks: [SeamTrack] = [
        track("Nightcall", "Kavinsky", state: .synced, isNew: true),
        track("Midnight City", "M83", state: .review(confidence: 86, reason: .versionDifference)),
        track("Running Up That Hill", "Kate Bush", album: "Hounds of Love", state: .synced),
        track("Tokyo Drift (Live Session)", "Teriyaki Boyz", state: .missing("Not on Apple Music in Germany")),
        track("A Real Hero", "College, Electric Youth", state: .synced, isNew: true),
        track("Tick of the Clock", "Chromatics", state: .synced)
    ]

    /// The storyboard's first-sync preview: +33 on Apple Music (29 exact, 3 close, 1 unavailable), +6 on Spotify.
    static func firstSyncPlan(pairId: UUID = lateNightDrive.id) -> PlannedSync {
        func t(_ n: Int, _ p: Platform) -> CatalogTrack {
            CatalogTrack(platform: p, id: "\(p.rawValue)-\(n)", title: "Track \(n)", artist: "Artist \(n)")
        }
        var rows: [PlanRow] = []
        var outcomes: [TrackKey: MatchOutcome] = [:]
        func pending(_ n: Int, from p: Platform, confidence: Int?) {
            let row = PlanRow(source: t(n, p), counterpartId: nil, state: .pending, removalFlag: nil, removalKept: false, retryCount: 0)
            rows.append(row)
            outcomes[row.key] = MatchOutcome(
                best: confidence.map { MatchCandidate(track: t(n, p.other), confidence: $0, reason: $0 == 100 ? .isrc : .versionDifference) },
                alternatives: [], alreadyInTarget: false
            )
        }
        for n in 0..<29 { pending(n, from: .spotify, confidence: 100) }
        for n in 29..<32 { pending(n, from: .spotify, confidence: 84) }
        pending(32, from: .spotify, confidence: nil)
        for n in 100..<106 { pending(n, from: .appleMusic, confidence: 100) }
        for n in 200..<231 {
            rows.append(PlanRow(source: t(n, .spotify), counterpartId: "am-\(n)", state: .synced, removalFlag: nil, removalKept: false, retryCount: 0))
        }
        let plan = PlanBuilder.build(PlanInput(
            pairId: pairId, direction: .bidirectional, sourcePlatform: .spotify, removalPolicy: .ask,
            confidence: ConfidencePolicy(), rows: rows, outcomes: outcomes, appleMusicCanRemove: false
        ))
        return PlannedSync(plan: plan, fingerprint: PlaylistFingerprint(spotifyTracks: [], appleMusicTracks: []), sourcePlatform: .spotify)
    }

    // MARK: - Builders

    static func seam(
        _ name: String, appleMusicName: String? = nil, direction: SyncDirection, monitored: Bool, paused: Bool = false,
        counts: SeamCounts, checkedMinutesAgo: Double
    ) -> SeamSummary {
        SeamSummary(
            id: UUID(),
            spotify: SeamSide(platform: .spotify, playlistId: "sp-\(name)", name: name, artworkURL: nil),
            appleMusic: SeamSide(platform: .appleMusic, playlistId: "am-\(name)", name: appleMusicName ?? name, artworkURL: nil),
            direction: direction, isMonitored: monitored, isPaused: paused, monitorIntervalMinutes: 15,
            lastCheckedAt: Date().addingTimeInterval(-checkedMinutesAgo * 60), lastResult: .success, counts: counts
        )
    }

    static func track(_ title: String, _ artist: String, album: String? = nil, state: TrackRowState, isNew: Bool = false) -> SeamTrack {
        SeamTrack(id: UUID(), title: title, artist: artist, album: album, artworkURL: nil, state: state, isNew: isNew)
    }
}

/// In-memory `SeamRepository` for previews.
actor PreviewSeamRepository: SeamRepository {
    private var summaries: [SeamSummary]
    private var rulesById: [UUID: SeamRules] = [:]

    init(seams: [SeamSummary] = PreviewFixtures.seams) {
        summaries = seams
    }

    func seams() async throws -> [SeamSummary] { summaries }

    func detail(for id: UUID) async throws -> SeamDetail? {
        guard let summary = summaries.first(where: { $0.id == id }) else { return nil }
        return SeamDetail(summary: summary, tracks: PreviewFixtures.lateNightDriveTracks)
    }

    func rules(for id: UUID) async throws -> SeamRules? {
        guard let summary = summaries.first(where: { $0.id == id }) else { return nil }
        return rulesById[id] ?? SeamRules(
            direction: summary.direction,
            removalPolicy: summary.direction == .bidirectional ? .ask : .keep,
            isMonitored: summary.isMonitored, monitorIntervalMinutes: nil,
            notifyNewTracks: false, isPaused: summary.isPaused
        )
    }

    func update(_ rules: SeamRules, for id: UUID) async throws { rulesById[id] = rules }
    func unlink(_ id: UUID) async throws { summaries.removeAll { $0.id == id } }
    func markViewed(_ id: UUID) async throws {}
}

/// `SyncService` that never touches a platform.
struct PreviewSyncService: SyncService {
    func preview(seamId: UUID, isFirstSync: Bool, progress: (@Sendable (Int, Int) async -> Void)?) async throws -> PlannedSync {
        PreviewFixtures.firstSyncPlan(pairId: seamId)
    }

    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger, progress: SyncProgressCallback?) async -> SyncResult {
        let total = planned.plan.automaticAddCount
        for done in stride(from: 0, through: total, by: max(1, total / 10)) {
            await progress?(SyncProgress(totalTracks: total, completedTracks: done, failedTracks: 0))
        }
        return SyncResult(pairId: planned.plan.pairId, status: .success, tracksAdded: total)
    }

    func undoPreview(runId: UUID) async throws -> UndoPlan {
        let am = (1...4).map { RecordedChange(kind: .add, platform: .appleMusic, track: CatalogTrack(platform: .appleMusic, id: "\($0)", title: "T", artist: "A")) }
        return UndoPlanner.plan(for: am, capabilities: .full)
    }

    func undo(runId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
}
#endif
