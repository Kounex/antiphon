import AntiphonDesign
import Foundation
import Observation

/// Preview → sync → result for one seam. Every write path goes through here,
/// so nothing changes until the person has seen the dry run.
@MainActor
@Observable
final class SyncFlowModel {
    enum Phase {
        case planning(checked: Int, total: Int)
        case preview
        case syncing
        case done(SyncResult)
        case failed(String)
    }

    let seamId: UUID
    let isFirstSync: Bool
    private(set) var phase: Phase = .planning(checked: 0, total: 0)
    private(set) var planned: PlannedSync?
    private(set) var seam: SeamSummary?
    private(set) var startedAt: Date?
    /// Set when a sync found the playlists changed and a new preview was made.
    private(set) var replannedNotice: String?

    private let sync: SyncService
    private let seams: SeamRepository
    /// For the version picker in the preview's track list.
    let search: CatalogSearchService?

    init(seamId: UUID, isFirstSync: Bool, sync: SyncService, seams: SeamRepository, search: CatalogSearchService? = nil) {
        self.seamId = seamId
        self.isFirstSync = isFirstSync
        self.sync = sync
        self.seams = seams
        self.search = search
    }

    func load() async {
        seam = try? await seams.detail(for: seamId)?.summary
        await plan()
    }

    /// Just the seam's name and covers, without planning — for a flow
    /// that's following an already-running sync rather than previewing one.
    func loadSeamIfNeeded() async {
        guard seam == nil else { return }
        seam = try? await seams.detail(for: seamId)?.summary
    }

    func plan() async {
        phase = .planning(checked: 0, total: 0)
        do {
            planned = try await sync.preview(seamId: seamId, isFirstSync: isFirstSync) { [weak self] checked, total in
                await MainActor.run { self?.phase = .planning(checked: checked, total: total) }
            }
            phase = .preview
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Hands the approved plan to the coordinator, which drives the accessory.
    /// Reopened from the progress bar while this seam syncs: show the live
    /// sheet for the running sync (no new preview), then its result.
    private(set) var isFollowing = false

    func followRunningSync() {
        isFollowing = true
        startedAt = startedAt ?? Date()
        phase = .syncing
    }

    /// A version picked from the preview's track list: kept for the seam, and
    /// the plan uses it. Nothing is written until the person syncs.
    func choose(_ candidate: MatchCandidate, for source: CatalogTrack) async throws {
        try await sync.keepPick(candidate.track, for: TrackKey(source), seamId: seamId)
        guard let planned else { return }
        self.planned = PlannedSync(plan: planned.plan.choosing(candidate.track, for: source),
                                   fingerprint: planned.fingerprint, sourcePlatform: planned.sourcePlatform)
    }

    /// The version picker for one planned song.
    func pickTarget(for source: CatalogTrack, planned match: MatchCandidate?, candidates: [MatchCandidate]) -> PickTarget? {
        guard let seam else { return nil }
        let current: PickTarget.Current = match.map { $0.reason == .manual ? .yourPick($0.track) : .antiphonsPick($0.track) } ?? .notThere
        return PickTarget(seam: seam, source: source, current: current, candidates: candidates)
    }

    var isSyncing: Bool {
        if case .syncing = phase { true } else { false }
    }

    /// Whether this flow is worth keeping once the sheet hides it: a running
    /// sync, or a result not yet acknowledged. An abandoned preview isn't.
    var keepsStateWhileHidden: Bool {
        switch phase {
        case .syncing, .done: true
        case .planning, .preview, .failed: false
        }
    }

    /// Reopened after being hidden: if the coordinator finished (or gave up)
    /// while no one was watching, catch up to its real result instead of
    /// sitting on a stale "syncing" phase.
    func reconcile(with coordinator: SyncCoordinator) async {
        guard case .syncing = phase, !coordinator.isSyncing(seamId) else { return }
        if let result = coordinator.lastResults[seamId] {
            await finished(with: result)
        } else {
            await plan()
        }
    }

    func start(using coordinator: SyncCoordinator) {
        guard let planned else { return }
        replannedNotice = nil
        startedAt = Date()
        phase = .syncing
        coordinator.startSync(
            pairId: seamId,
            action: isFirstSync ? .initialSync : .manualSync,
            planned: planned,
            trigger: isFirstSync ? .firstSync : .manual
        )
    }

    /// Called when the coordinator reports the run finished.
    func finished(with result: SyncResult) async {
        if result.isStale {
            replannedNotice = "The playlists changed since the preview. Here's what will happen now."
            await plan()
        } else {
            phase = .done(result)
        }
    }

    // MARK: - Presentation

    func playlistName(on platform: Platform) -> String {
        seam?.side(platform).name ?? platform.rawValue
    }

    var headline: String {
        planned.map { PlanCopy.headline(for: $0.plan) } ?? ""
    }

    /// Sides with something to show, the seam's target first.
    var sides: [SyncPlan.Side] {
        guard let plan = planned?.plan, let seam else { return [] }
        let order: [Platform] = [seam.source.other, seam.source]
        return order.map(plan.side).filter { $0.missingCount > 0 || !$0.removals.isEmpty }
    }

    var writeCount: Int {
        guard let plan = planned?.plan else { return 0 }
        return plan.automaticAddCount + plan.removalCount
    }

    /// What happens once the plan is applied.
    enum AfterApply: Equatable {
        /// Tracks were written: show the outcome.
        case showResult
        /// Only removals to decide: they're recorded, then asked about.
        case openConflicts
        /// Nothing changed: the check is recorded and the flow closes.
        case dismiss
    }

    var conflictCount: Int { planned?.plan.conflicts.count ?? 0 }

    var afterApply: AfterApply {
        if isFollowing || writeCount > 0 { return .showResult }
        return conflictCount > 0 ? .openConflicts : .dismiss
    }

    var primaryTitle: String {
        switch afterApply {
        case .showResult: "Sync \(PlanCopy.count(writeCount, "track")) now"
        case .openConflicts: "Decide about \(PlanCopy.count(conflictCount, "removal"))"
        case .dismiss: planned?.plan.reorders.map { "Reorder \($0.rawValue)" } ?? "Done"
        }
    }

    var primarySymbol: String {
        switch afterApply {
        case .showResult: "arrow.triangle.2.circlepath"
        case .openConflicts: "questionmark.circle"
        case .dismiss: "checkmark"
        }
    }

    var conflictTitles: [String] {
        planned?.plan.conflicts.map(\.track.title) ?? []
    }

    /// Tracks this run writes, in the order the engine processes them.
    var plannedWrites: [SyncPlan.Add] {
        sides.flatMap(\.automaticAdds)
    }

    var reviewTitles: [String] {
        sides.flatMap(\.reviewAdds).map(\.source.title)
    }

    var unavailableTitles: [String] {
        sides.flatMap(\.unavailable).map(\.source.title)
    }

    #if DEBUG
    func debugStart() { startedAt = Date().addingTimeInterval(-53); phase = .syncing }
    func debugFinish(_ result: SyncResult) { phase = .done(result) }
    #endif

    static func message(for error: Error) -> String {
        if let stopped = error as? PlanningStopped { return stopped.message }
        if case .stop(let message) = CatalogFailure.classify(error) { return message }
        return switch error {
        case SyncError.appleMusicPlaylistNotFound: "The Apple Music playlist couldn't be found. It may have been deleted."
        case SyncError.spotifyPlaylistNotFound: "The Spotify playlist couldn't be found. It may have been deleted."
        case AppleMusicError.notAuthorized: "Antiphon can't reach Apple Music. Allow access in Settings › Antiphon."
        default: "Antiphon couldn't read the playlists. Check your connection and try again."
        }
    }
}
