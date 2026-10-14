import Foundation
import SwiftData
import UserNotifications

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
    /// The person's version for a song, kept for the seam and written now
    /// when the song is stored (swapped in for a synced one).
    func choose(_ candidate: MatchCandidate, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome
    /// Keeps a pick without writing (a preview).
    func keepPick(_ track: CatalogTrack, for key: TrackKey, seamId: UUID) async throws
    /// "Let Antiphon choose again".
    func forgetPick(for key: TrackKey, seamId: UUID) async throws
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
            versionPreferences: preferences.versionPreferences, capabilities: capabilities,
            recheck: preferences.recheckCadence
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
        let outcome = try await runner().undo(runId: runId)
        WidgetSnapshotWriter.schedule(modelContainer: modelContainer)
        return outcome
    }

    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome {
        let outcome = try await runner().resolve(resolutions, pairId: seamId)
        // Answered: its notification, if any, has nothing left to ask.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: resolutions.map { QuestionNotice.id(seamId: seamId, key: $0.conflict.key) })
        WidgetSnapshotWriter.schedule(modelContainer: modelContainer)
        return outcome
    }

    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome {
        let outcome = try await runner().decide(decision, for: key, pairId: seamId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [QuestionNotice.id(seamId: seamId, key: key)])
        WidgetSnapshotWriter.schedule(modelContainer: modelContainer)
        return outcome
    }

    func choose(_ candidate: MatchCandidate, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome {
        let outcome = try await runner().choose(candidate, for: key, pairId: seamId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [QuestionNotice.id(seamId: seamId, key: key)])
        WidgetSnapshotWriter.schedule(modelContainer: modelContainer)
        return outcome
    }

    func keepPick(_ track: CatalogTrack, for key: TrackKey, seamId: UUID) async throws {
        try await runner().keepPick(track, for: key, pairId: seamId)
    }

    func forgetPick(for key: TrackKey, seamId: UUID) async throws {
        try await runner().forgetPick(for: key, pairId: seamId)
    }

    private func runner() -> OperationRunner {
        OperationRunner(
            modelContainer: modelContainer,
            editor: LivePlaylistEditor(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager()),
            capabilities: capabilities
        )
    }
}
