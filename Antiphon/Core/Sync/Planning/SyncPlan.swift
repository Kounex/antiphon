import Foundation

/// Identifies a track by where it was loaded from, stable between planning
/// and applying (cache rows are rebuilt from the same platform IDs).
struct TrackKey: Hashable, Sendable {
    let platform: Platform
    let id: String

    init(platform: Platform, id: String) {
        self.platform = platform
        self.id = id
    }

    init(_ track: CatalogTrack) {
        self.init(platform: track.platform, id: track.id)
    }
}

/// What searching the other catalog found for one track.
struct MatchOutcome: Sendable, Equatable {
    /// The highest-scoring candidate, if any.
    var best: MatchCandidate?
    /// The other candidates, best first.
    var alternatives: [MatchCandidate]
    /// The target playlist already holds this track, so nothing needs adding.
    var alreadyInTarget: Bool
}

/// A dry run of one sync: everything that would change, without changing anything.
struct SyncPlan: Sendable {
    let pairId: UUID
    let createdAt: Date
    /// One entry per platform, keyed by the platform the changes land on.
    let sides: [Platform: Side]
    let conflicts: [Conflict]
    let inSyncCount: Int

    struct Side: Sendable, Equatable {
        let platform: Platform
        var automaticAdds: [Add] = []
        var reviewAdds: [Add] = []
        var unavailable: [Unavailable] = []
        var removals: [Removal] = []
        /// Matched tracks the target playlist already holds: nothing to write.
        var alreadyPresent: [Add] = []

        /// Tracks on the other side that this side doesn't have yet,
        /// whether or not they'll be added now ("+33").
        var missingCount: Int { automaticAdds.count + reviewAdds.count + unavailable.count }
    }

    struct Add: Sendable, Equatable {
        let source: CatalogTrack
        let match: MatchCandidate
        let alternatives: [MatchCandidate]
    }

    struct Unavailable: Sendable, Equatable {
        let source: CatalogTrack
        /// Low-confidence candidates, offered but never added automatically.
        let alternatives: [MatchCandidate]
    }

    struct Removal: Sendable, Equatable {
        /// The track to remove, identified on the platform it's removed from.
        let track: CatalogTrack
        /// The platform can't remove tracks itself, so the person is shown how.
        let isGuided: Bool
    }

    struct Conflict: Sendable, Equatable {
        let key: TrackKey
        let track: CatalogTrack
        let removedFrom: Platform
        let noticedAt: Date?
        /// The track on the side that still has it.
        var remaining: CatalogTrack? = nil
        /// The track as it was identified on the side it was removed from.
        var removed: CatalogTrack? = nil
    }

    func side(_ platform: Platform) -> Side {
        sides[platform] ?? Side(platform: platform)
    }

    var totalMissing: Int { sides.values.reduce(0) { $0 + $1.missingCount } }
    var automaticAddCount: Int { sides.values.reduce(0) { $0 + $1.automaticAdds.count } }
    var reviewCount: Int { sides.values.reduce(0) { $0 + $1.reviewAdds.count } }
    var unavailableCount: Int { sides.values.reduce(0) { $0 + $1.unavailable.count } }
    /// Removals Antiphon will carry out itself. Guided removals aren't writes.
    var removalCount: Int {
        sides.values.reduce(0) { $0 + $1.removals.filter { !$0.isGuided }.count }
    }
    var isEmpty: Bool { automaticAddCount == 0 && reviewCount == 0 && removalCount == 0 && conflicts.isEmpty }
}

// MARK: - Decisions

/// What applying a plan does with one track, keyed by `TrackKey`.
enum PlannedDecision: Sendable, Equatable {
    case add(MatchCandidate)
    case review(MatchCandidate, alternatives: [MatchCandidate])
    case unavailable(alternatives: [MatchCandidate])
    case alreadyPresent(MatchCandidate)

    var writesTrack: Bool {
        if case .add = self { true } else { false }
    }
}

extension SyncPlan {
    /// Decisions for every planned track. Close matches the person approved
    /// in the preview become adds; the rest wait in the review queue.
    func decisions(approving approved: Set<TrackKey> = []) -> [TrackKey: PlannedDecision] {
        var result: [TrackKey: PlannedDecision] = [:]
        for side in sides.values {
            for add in side.automaticAdds { result[TrackKey(add.source)] = .add(add.match) }
            for add in side.reviewAdds {
                let key = TrackKey(add.source)
                result[key] = approved.contains(key) ? .add(add.match) : .review(add.match, alternatives: add.alternatives)
            }
            for item in side.unavailable { result[TrackKey(item.source)] = .unavailable(alternatives: item.alternatives) }
            for add in side.alreadyPresent { result[TrackKey(add.source)] = .alreadyPresent(add.match) }
        }
        return result
    }
}
