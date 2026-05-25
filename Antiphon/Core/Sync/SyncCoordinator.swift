import Foundation
import SwiftData
import Observation

/// Coordinates sync operations across the app, running them as background tasks
/// that don't block the UI. Observable so views can react to sync state changes.
@Observable
final class SyncCoordinator: @unchecked Sendable {
    
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
    @MainActor
    func startSync(
        pairId: UUID,
        action: SyncAction,
        spotifyAuth: SpotifyAuthManager
    ) {
        // Don't start if already syncing this pair
        guard !syncingPairIds.contains(pairId) else { return }
        
        syncingPairIds.insert(pairId)
        lastResults[pairId] = nil
        syncProgress[pairId] = SyncProgress(totalTracks: 0, completedTracks: 0, failedTracks: 0)
        
        let container = modelContainer
        let coordinator = self
        let task = Task { @Sendable in
            let appleMusicManager = AppleMusicManager()
            let spotifyClient = SpotifyAPIClient(authManager: spotifyAuth)
            
            let engine = SyncEngine(
                modelContainer: container,
                spotifyClient: spotifyClient,
                appleMusicManager: appleMusicManager
            )
            
            let result = await engine.syncPair(pairId, action: action) { progress in
                await MainActor.run {
                    coordinator.syncProgress[pairId] = progress
                }
            }
            
            await MainActor.run {
                coordinator.syncingPairIds.remove(pairId)
                coordinator.runningTasks[pairId] = nil
                coordinator.syncProgress[pairId] = nil
                coordinator.lastResults[pairId] = result
            }
            
            return result
        }
        
        runningTasks[pairId] = task
    }
    
    /// Cancels an in-progress sync for a specific pair.
    @MainActor
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
    
    /// Cancels all running syncs.
    @MainActor
    func cancelAll() {
        for (pairId, task) in runningTasks {
            task.cancel()
            lastResults[pairId] = SyncResult(
                pairId: pairId,
                status: .failed,
                message: "Sync cancelled"
            )
        }
        runningTasks.removeAll()
        syncingPairIds.removeAll()
        syncProgress.removeAll()
    }
    
    /// Updates progress for a syncing pair. Called by SyncEngine from background.
    @MainActor
    func updateProgress(pairId: UUID, progress: SyncProgress) {
        syncProgress[pairId] = progress
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
