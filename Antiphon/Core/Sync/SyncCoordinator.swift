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
    
    /// Currently running sync tasks, keyed by SyncPair ID.
    private var runningTasks: [UUID: Task<SyncResult, Never>] = [:]
    
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
        
        let container = modelContainer
        let task = Task {
            let appleMusicManager = AppleMusicManager()
            let spotifyClient = SpotifyAPIClient()
            
            let engine = SyncEngine(
                modelContainer: container,
                spotifyClient: spotifyClient,
                appleMusicManager: appleMusicManager
            )
            
            let result = await engine.syncPair(pairId, action: action) { [weak self] progress in
                await MainActor.run {
                    self?.syncProgress[pairId] = progress
                }
            }
            
            syncingPairIds.remove(pairId)
            runningTasks[pairId] = nil
            syncProgress[pairId] = nil
            lastResults[pairId] = result
            
            return result
        }
        
        runningTasks[pairId] = task
    }
    
    /// Cancels all in-progress syncs and waits for them to unwind. Call before
    /// destructive operations such as "Reset All Data" so no running task is
    /// still mid-write when the store is wiped.
    func cancelAllSyncs() async {
        let tasks = runningTasks
        for pairId in tasks.keys {
            cancelSync(pairId: pairId)
        }
        // Engines only observe cancellation at loop checkpoints — await the
        // task handles so the caller knows all writes have quiesced.
        for task in tasks.values {
            _ = await task.value
        }
    }

    /// Cancels an in-progress sync for a specific pair.
    func cancelSync(pairId: UUID) {
        runningTasks[pairId]?.cancel()
        runningTasks[pairId] = nil
        syncingPairIds.remove(pairId)
        syncProgress[pairId] = nil
        lastResults[pairId] = SyncResult(
            pairId: pairId,
            status: .failed,
            message: "Sync cancelled by user"
        )
    }
}

// MARK: - Sync Progress

/// Real-time progress of a sync operation.
struct SyncProgress: Sendable {
    var totalTracks: Int
    var completedTracks: Int
    var failedTracks: Int
    var currentTrackName: String?
    
    var fraction: Double {
        guard totalTracks > 0 else { return 0 }
        return Double(completedTracks + failedTracks) / Double(totalTracks)
    }
    
    var summary: String {
        "\(completedTracks + failedTracks)/\(totalTracks)"
    }
}
