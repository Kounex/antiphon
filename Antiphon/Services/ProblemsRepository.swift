import Foundation
import SwiftData

/// An open problem, as a value.
struct ProblemRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ProblemKind
    let platform: Platform?
    let seamId: UUID?
    let message: String
    let firstSeenAt: Date
    let retryAt: Date?
    /// A deleted playlist the other side can fill again.
    var canRecreate = false
}

protocol ProblemsRepository: Sendable {
    /// Unresolved problems, oldest first.
    func problems() async throws -> [ProblemRecord]
    /// For a deleted playlist: the seam gets a new playlist on that side,
    /// created and filled from the other side by its next sync, which the
    /// person previews. Returns the seam. Nothing is written here.
    func recreatePlaylist(for problemId: UUID) async throws -> UUID
}

extension SwiftDataSeamRepository: ProblemsRepository {
    func problems() async throws -> [ProblemRecord] {
        let context = ModelContext(modelContainerForReview)
        let open = try context.fetch(FetchDescriptor<SyncProblem>(
            predicate: #Predicate { $0.resolvedAt == nil }, sortBy: [SortDescriptor(\.firstSeenAt)]
        ))
        return open.map { problem in
            var canRecreate = false
            if problem.kind == .playlistDeleted, let platform = problem.platform, let pair = problem.pair {
                canRecreate = SeamRecreation.canRecreate(direction: pair.syncDirection, deleted: platform)
            }
            return ProblemRecord(id: problem.id, kind: problem.kind, platform: problem.platform, seamId: problem.pair?.id,
                                 message: problem.message, firstSeenAt: problem.firstSeenAt, retryAt: problem.retryAt,
                                 canRecreate: canRecreate)
        }
    }

    /// The seam ends up exactly as New seam leaves one whose twin is still
    /// to be created: that side waits for creation, no tracks are stored,
    /// and the first sync is previewed. Rules, history and picks stay.
    func recreatePlaylist(for problemId: UUID) async throws -> UUID {
        let context = ModelContext(modelContainerForReview)
        guard let problem = try context.fetch(FetchDescriptor<SyncProblem>(predicate: #Predicate { $0.id == problemId })).first,
              problem.kind == .playlistDeleted, let platform = problem.platform, let pair = problem.pair,
              SeamRecreation.canRecreate(direction: pair.syncDirection, deleted: platform) else {
            throw SeamRecreation.Failure.notRecreatable
        }
        let pending = "pending-creation-\(UUID().uuidString)"
        switch platform {
        case .spotify:
            pair.spotifyPlaylistId = pending
            pair.spotifySnapshotId = nil
            pair.spotifyImageURL = nil
            pair.spotifyCreatedByAntiphon = false
        case .appleMusic:
            pair.appleMusicPlaylistId = pending
            pair.appleMusicImageURL = nil
            pair.appleMusicCreatedByAntiphon = false
        }
        // The stored tracks describe a playlist that no longer exists.
        for track in pair.cachedTracks { context.delete(track) }
        pair.lastSyncedAt = nil
        pair.lastSyncResult = nil
        pair.lastSyncMessage = nil
        pair.lastInterruptedAt = nil
        pair.needsRebuild = false
        pair.unchangedToken = nil
        problem.resolvedAt = Date()
        try context.save()
        return pair.id
    }
}
