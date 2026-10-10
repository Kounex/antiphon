import Foundation
import SwiftData

/// Everything that changes playlists, behind one protocol so views can be
/// previewed with mock data. Every write path starts from a preview.
protocol SyncService: Sendable {
    /// A dry run of the next sync. Writes nothing.
    func preview(seamId: UUID, isFirstSync: Bool,
                 progress: (@Sendable (_ checked: Int, _ total: Int) async -> Void)?) async throws -> PlannedSync
    /// Applies exactly what the preview showed. Returns `isStale` if either
    /// playlist changed since, without writing.
    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger,
               progress: SyncProgressCallback?) async -> SyncResult
    func undoPreview(runId: UUID) async throws -> UndoPlan
    func undo(runId: UUID) async throws -> OperationRunner.Outcome
    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome
    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome
}

/// `SyncService` over the existing engine and clients. Each call builds its
/// own clients, as the coordinator and background tasks already do.
struct LiveSyncService: SyncService {
    let modelContainer: ModelContainer
    var preferences: AppPreferences = .shared
    /// `nil` uses each seam's own capabilities.
    var capabilities: PlatformCapabilities? = nil

    func preview(seamId: UUID, isFirstSync: Bool,
                 progress: (@Sendable (Int, Int) async -> Void)?) async throws -> PlannedSync {
        let planner = SyncPlanner(
            modelContainer: modelContainer, spotifyClient: SpotifyAPIClient(),
            appleMusicManager: AppleMusicManager(), confidence: preferences.confidencePolicy,
            versionPreferences: preferences.versionPreferences, capabilities: capabilities
        )
        return try await planner.plan(pairId: seamId, action: isFirstSync ? .initialSync : .manualSync, progress: progress)
    }

    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger,
               progress: SyncProgressCallback?) async -> SyncResult {
        let engine = SyncEngine(modelContainer: modelContainer, spotifyClient: SpotifyAPIClient(),
                                appleMusicManager: AppleMusicManager())
        let action: SyncAction = trigger == .firstSync ? .initialSync : .manualSync
        return await engine.syncPair(planned.plan.pairId, action: action, trigger: trigger, planned: planned,
                                     approving: approving, progressCallback: progress)
    }

    func undoPreview(runId: UUID) async throws -> UndoPlan {
        try await runner().undoPreview(runId: runId)
    }

    func undo(runId: UUID) async throws -> OperationRunner.Outcome {
        try await runner().undo(runId: runId)
    }

    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome {
        try await runner().resolve(resolutions, pairId: seamId)
    }

    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome {
        try await runner().decide(decision, for: key, pairId: seamId)
    }

    private func runner() -> OperationRunner {
        OperationRunner(
            modelContainer: modelContainer,
            editor: LivePlaylistEditor(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager()),
            capabilities: capabilities
        )
    }
}
