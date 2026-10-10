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

    init(seamId: UUID, isFirstSync: Bool, sync: SyncService, seams: SeamRepository) {
        self.seamId = seamId
        self.isFirstSync = isFirstSync
        self.sync = sync
        self.seams = seams
    }

    func load() async {
        seam = try? await seams.detail(for: seamId)?.summary
        await plan()
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

    var primaryTitle: String {
        writeCount == 0 ? "Done" : "Sync \(PlanCopy.count(writeCount, "track")) now"
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
        switch error {
        case SyncError.appleMusicPlaylistNotFound: "The Apple Music playlist couldn't be found. It may have been deleted."
        case SyncError.spotifyPlaylistNotFound: "The Spotify playlist couldn't be found. It may have been deleted."
        case AppleMusicError.notAuthorized: "Antiphon can't reach Apple Music. Allow access in Settings › Antiphon."
        default: "Antiphon couldn't read the playlists. Check your connection and try again."
        }
    }
}
