import Foundation
import SwiftData

/// A close match waiting for the person's call.
struct ReviewItem: Identifiable, Hashable, Sendable {
    /// The cache row's ID.
    let id: UUID
    let seamId: UUID
    let seamName: String
    /// Identifies the row for `SyncService.decide`.
    let key: TrackKey
    let source: CatalogTrack
    /// Best first.
    let candidates: [MatchCandidate]

    var best: MatchCandidate? { candidates.first }
    var targetPlatform: Platform { source.platform.other }
}

/// A removal in a seam that asks before removing, waiting for an answer.
struct ConflictItem: Identifiable, Sendable {
    let seamId: UUID
    let seamName: String
    let conflict: SyncPlan.Conflict
    /// The playlist that still has the track.
    let remainingPlaylistName: String
    /// Apple Music removals work only on playlists Antiphon created (D1).
    var appleMusicCanRemove: Bool = false
    /// The cache row, so a tapped track row can open its question.
    var rowId: UUID? = nil
    var id: TrackKey { conflict.key }
}

/// What needs the person: close matches and removals.
protocol ReviewRepository: Sendable {
    func reviewItems(seamId: UUID?) async throws -> [ReviewItem]
    func conflicts(seamId: UUID?) async throws -> [ConflictItem]
}

extension SwiftDataSeamRepository: ReviewRepository {

    func reviewItems(seamId: UUID?) async throws -> [ReviewItem] {
        try pairs(seamId).flatMap { pair -> [ReviewItem] in
            let seamSource = Self.seamSource(pair)
            return pair.cachedTracks
                .filter { $0.effectiveSyncState == .needsReview }
                .sorted { $0.addedAt < $1.addedAt }
                .compactMap { row in
                    guard let planRow = row.planRow(seamSource: seamSource) else { return nil }
                    return ReviewItem(
                        id: row.id, seamId: pair.id, seamName: Self.name(of: pair), key: planRow.key,
                        source: planRow.source, candidates: row.candidates.sorted { $0.confidence > $1.confidence }
                    )
                }
        }
    }

    func conflicts(seamId: UUID?) async throws -> [ConflictItem] {
        try pairs(seamId).flatMap { pair -> [ConflictItem] in
            let seamSource = Self.seamSource(pair)
            let flagged = pair.cachedTracks
                .filter { $0.removalFlag != nil && $0.removalKeptAt == nil }
                .sorted { $0.addedAt < $1.addedAt }
            return flagged.compactMap { row -> ConflictItem? in
                guard let planRow = row.planRow(seamSource: seamSource) else { return nil }
                // The same rules a sync uses decide what's a question.
                let plan = PlanBuilder.build(PlanInput(
                    pairId: pair.id, direction: pair.syncDirection, sourcePlatform: seamSource,
                    removalPolicy: pair.effectiveRemovalPolicy, confidence: ConfidencePolicy(),
                    rows: [planRow], outcomes: [:], appleMusicCanRemove: false
                ))
                guard let conflict = plan.conflicts.first else { return nil }
                let remaining = conflict.removedFrom.other
                return ConflictItem(
                    seamId: pair.id, seamName: Self.name(of: pair), conflict: conflict,
                    remainingPlaylistName: remaining == .spotify ? pair.spotifyPlaylistName : pair.appleMusicPlaylistName,
                    appleMusicCanRemove: pair.appleMusicCreatedByAntiphon, rowId: row.id
                )
            }
        }
    }

    // MARK: - Private

    private func pairs(_ seamId: UUID?) throws -> [SyncPair] {
        let context = ModelContext(modelContainerForReview)
        if let seamId {
            return try context.fetch(FetchDescriptor<SyncPair>(predicate: #Predicate { $0.id == seamId }))
        }
        return try context.fetch(FetchDescriptor<SyncPair>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    static func seamSource(_ pair: SyncPair) -> Platform {
        pair.syncDirection == .appleToSpotify ? .appleMusic : .spotify
    }

    static func name(of pair: SyncPair) -> String {
        pair.syncDirection == .appleToSpotify ? pair.appleMusicPlaylistName : pair.spotifyPlaylistName
    }
}
