import Foundation

/// The three answers to "this track was removed on one side of a two-way seam".
enum ConflictOutcome: Sendable, CaseIterable {
    /// Remove it from the side that still has it, so both match again.
    case removeOnOtherSide
    /// Put it back where it was removed.
    case restore
    /// Leave both playlists as they are and stop asking about this track.
    case keepDifference
}

struct ConflictResolution: Sendable, Equatable {
    enum RowUpdate: Sendable, Equatable {
        /// The track left both playlists: stop tracking it in this seam.
        case forget
        /// The track is on both sides again.
        case restore
        /// Ignore the difference from now on (sets `removalKeptAt`).
        case keepDifference
    }

    let conflict: SyncPlan.Conflict
    let operations: [SyncOperation]
    let rowUpdate: RowUpdate
}

enum ConflictResolver {

    static func resolve(
        _ conflict: SyncPlan.Conflict,
        as outcome: ConflictOutcome,
        appleMusicCanRemove: Bool
    ) -> ConflictResolution {
        let capabilities = PlatformCapabilities(appleMusicCanRemove: appleMusicCanRemove, appleMusicCanReorder: false)

        switch outcome {
        case .removeOnOtherSide:
            let platform = conflict.removedFrom.other
            let guided = capabilities.isGuided(.remove, on: platform)
            let operation = SyncOperation(
                kind: .remove, platform: platform,
                track: conflict.remaining ?? identified(conflict.track, on: platform),
                isGuided: guided
            )
            // A guided removal hasn't happened yet; the next sync sees it once it has.
            return ConflictResolution(conflict: conflict, operations: [operation], rowUpdate: guided ? .keepDifference : .forget)

        case .restore:
            let platform = conflict.removedFrom
            let operation = SyncOperation(
                kind: .add, platform: platform,
                track: conflict.removed ?? identified(conflict.track, on: platform)
            )
            return ConflictResolution(conflict: conflict, operations: [operation], rowUpdate: .restore)

        case .keepDifference:
            return ConflictResolution(conflict: conflict, operations: [], rowUpdate: .keepDifference)
        }
    }

    /// "Do the same for N other removals."
    static func resolveAll(
        _ conflicts: [SyncPlan.Conflict],
        as outcome: ConflictOutcome,
        appleMusicCanRemove: Bool
    ) -> [ConflictResolution] {
        conflicts.map { resolve($0, as: outcome, appleMusicCanRemove: appleMusicCanRemove) }
    }

    /// The confirm button repeats the chosen outcome as a verb.
    static func buttonTitle(for conflict: SyncPlan.Conflict, outcome: ConflictOutcome) -> String {
        switch outcome {
        case .removeOnOtherSide: "Remove from \(conflict.removedFrom.other.rawValue)"
        case .restore: "Put back on \(conflict.removedFrom.rawValue)"
        case .keepDifference: "Keep the difference"
        }
    }

    private static func identified(_ track: CatalogTrack, on platform: Platform) -> CatalogTrack {
        var copy = track
        copy.platform = platform
        return copy
    }
}
