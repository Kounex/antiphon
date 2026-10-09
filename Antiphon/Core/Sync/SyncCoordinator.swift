import Foundation
import SwiftData
import Observation

/// Coordinates sync operations across the app, running them as background tasks
/// that don't block the UI. Observable so views can react to sync state changes.
///
/// Fully `@MainActor`-isolated: all state is UI-owned and consumed by SwiftUI views.
/// Background sync work runs on the `SyncEngine` actor; the coordinator only manages
/// task handles and progress state on the main actor.
@MainActor
@Observable
final class SyncCoordinator {
    
    // MARK: - State
    
    /// A sync task plus a unique run ID, so a finishing task can tell whether
    /// it is still the pair's current run.
    private struct RunningSync {
        let runId: UUID
        let task: Task<SyncResult, Never>
    }
    
    /// Sync tasks that have not finished yet, keyed by SyncPair ID. A cancelled
    /// task stays here until it has actually unwound, so callers can await it.
    private var runningTasks: [UUID: RunningSync] = [:]
    
    /// Runs the user cancelled. Their results must not replace the
    /// "cancelled" result shown in the UI.
    private var cancelledRunIds: Set<UUID> = []
    
    /// IDs of pairs currently being synced — drives UI indicators.
    private(set) var syncingPairIds: Set<UUID> = []
    
    /// Last result per pair — cleared on next sync start.
    private(set) var lastResults: [UUID: SyncResult] = [:]
    
    /// Real-time progress per pair — updated track-by-track during sync.
    private(set) var syncProgress: [UUID: SyncProgress] = [:]
    
    // MARK: - Dependencies
    
    private let modelContainer: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    
    // MARK: - Public API
    
    /// Whether a specific pair is currently syncing.
    func isSyncing(_ pairId: UUID) -> Bool {
        syncingPairIds.contains(pairId)
    }
    
    /// Whether any sync is running.
    var isAnySyncRunning: Bool {
        !syncingPairIds.isEmpty
    }
    
    /// Starts a sync for a given pair in the background.
    /// Returns immediately — observe `syncingPairIds` for progress.
    func startSync(pairId: UUID, action: SyncAction) {
        guard !syncingPairIds.contains(pairId) else { return }
        
        syncingPairIds.insert(pairId)
        lastResults[pairId] = nil
        syncProgress[pairId] = SyncProgress(totalTracks: 0, completedTracks: 0, failedTracks: 0)
        
        // A cancelled run may still be unwinding; the engine rejects a second
        // concurrent run for the same pair, so wait for it first.
        let previousTask = runningTasks[pairId]?.task
        let runId = UUID()
        let container = modelContainer
        let task = Task {
            _ = await previousTask?.value
            
            let result: SyncResult
            if Task.isCancelled {
                result = SyncResult(pairId: pairId, status: .failed, message: "Sync cancelled by user")
            } else {
                let appleMusicManager = AppleMusicManager()
                let spotifyClient = SpotifyAPIClient()
                
                let engine = SyncEngine(
                    modelContainer: container,
                    spotifyClient: spotifyClient,
                    appleMusicManager: appleMusicManager
                )
                
                result = await engine.syncPair(pairId, action: action) { [weak self] progress in
                    await MainActor.run {
                        guard self?.runningTasks[pairId]?.runId == runId,
                              self?.cancelledRunIds.contains(runId) == false else { return }
                        self?.syncProgress[pairId] = progress
                    }
                }
            }
            
            finishRun(pairId: pairId, runId: runId, result: result)
            return result
        }
        
        runningTasks[pairId] = RunningSync(runId: runId, task: task)
    }
    
    /// Clears a finished run's state — only if it is still the pair's current
    /// run, so a cancelled run unwinding late never clobbers a newer one.
    private func finishRun(pairId: UUID, runId: UUID, result: SyncResult) {
        let wasCancelled = cancelledRunIds.remove(runId) != nil
        guard runningTasks[pairId]?.runId == runId else { return }
        
        runningTasks[pairId] = nil
        if !wasCancelled {
            syncingPairIds.remove(pairId)
            syncProgress[pairId] = nil
            lastResults[pairId] = result
        }
    }
    
    /// Cancels all in-progress syncs and waits for them to unwind. Call before
    /// destructive operations such as "Reset All Data" so no running task is
    /// still mid-write when the store is wiped.
    func cancelAllSyncs() async {
        for pairId in Array(runningTasks.keys) {
            cancelSync(pairId: pairId)
        }
        for pairId in Array(runningTasks.keys) {
            await waitForSyncToFinish(pairId: pairId)
        }
    }

    /// Cancels an in-progress sync for a specific pair. Returns immediately;
    /// the engine stops at its next checkpoint. Use `waitForSyncToFinish`
    /// before deleting anything the sync may still write to.
    func cancelSync(pairId: UUID) {
        if let running = runningTasks[pairId] {
            running.task.cancel()
            cancelledRunIds.insert(running.runId)
        }
        syncingPairIds.remove(pairId)
        syncProgress[pairId] = nil
        lastResults[pairId] = SyncResult(
            pairId: pairId,
            status: .failed,
            message: "Sync cancelled by user"
        )
    }
    
    /// Waits until no sync task for the pair is running, including cancelled
    /// tasks still unwinding. Engines only observe cancellation at loop
    /// checkpoints, so this is what guarantees their writes have quiesced.
    func waitForSyncToFinish(pairId: UUID) async {
        while let running = runningTasks[pairId] {
            _ = await running.task.value
            // finishRun has cleared the entry unless a newer run replaced it.
            if runningTasks[pairId]?.runId == running.runId { break }
        }
    }
}

// MARK: - Sync Progress

/// Real-time progress of a sync operation.
struct SyncProgress: Sendable {
    var totalTracks: Int
    var completedTracks: Int
    var failedTracks: Int
    var currentTrackName: String?
    /// Matching runs first; queued writes to the target platform happen
    /// afterwards and are counted separately (Apple Music adds one song at
    /// a time, so this phase can take a while).
    var phase: SyncPhase = .matching
    
    var fraction: Double {
        guard totalTracks > 0 else { return 0 }
        return Double(completedTracks + failedTracks) / Double(totalTracks)
    }
    
    var summary: String {
        "\(completedTracks + failedTracks)/\(totalTracks)"
    }
    
    /// Short status line, e.g. "Syncing 12/34" or "Adding 5/33 to Apple Music".
    var statusText: String {
        switch phase {
        case .matching: "Syncing \(summary)"
        case .adding(let platformName): "Adding \(summary) to \(platformName)"
        }
    }
}

enum SyncPhase: Sendable, Equatable {
    case matching
    case adding(platformName: String)
}
