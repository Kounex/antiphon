import Foundation

/// One cached track as Stage A left it, reduced to what planning needs.
struct PlanRow: Sendable {
    /// The track on the side it was loaded from.
    let source: CatalogTrack
    /// Its ID on the other side, when known.
    let counterpartId: String?
    let state: TrackSyncState
    let removalFlag: RemovalFlag?
    let removalKept: Bool
    let retryCount: Int
    var removalFlaggedAt: Date? = nil

    var key: TrackKey { TrackKey(source) }
}

struct PlanInput: Sendable {
    let pairId: UUID
    let direction: SyncDirection
    /// The side Stage A treated as the source (decides what `.removedFromSource` means).
    let sourcePlatform: Platform
    let removalPolicy: RemovalPolicy
    let confidence: ConfidencePolicy
    let rows: [PlanRow]
    /// Search results for the rows that need adding, keyed by row.
    let outcomes: [TrackKey: MatchOutcome]
    /// Whether removing tracks on Apple Music has been proven to work.
    let appleMusicCanRemove: Bool
}

/// Turns Stage A's cache state plus match results into a `SyncPlan`.
/// Pure: no I/O, no persistence.
enum PlanBuilder {
    static let maxRetries = 3

    static func build(_ input: PlanInput, now: Date = Date()) -> SyncPlan {
        var sides: [Platform: SyncPlan.Side] = [
            .spotify: SyncPlan.Side(platform: .spotify),
            .appleMusic: SyncPlan.Side(platform: .appleMusic)
        ]
        var conflicts: [SyncPlan.Conflict] = []
        var inSync = 0

        for row in input.rows {
            if let flag = row.removalFlag {
                planRemoval(row, flag: flag, input: input, sides: &sides, conflicts: &conflicts)
                continue
            }

            if row.state == .synced || row.state == .skipped {
                inSync += 1
                continue
            }

            let needsWork = row.state == .pending || (row.state == .failed && row.retryCount < maxRetries)
            let target = row.source.platform.other
            guard needsWork, allows(input.direction, from: row.source.platform),
                  let outcome = input.outcomes[row.key] else { continue }

            if outcome.alreadyInTarget {
                inSync += 1
                continue
            }

            guard let best = outcome.best else {
                sides[target]?.unavailable.append(.init(source: row.source, alternatives: outcome.alternatives))
                continue
            }

            let add = SyncPlan.Add(source: row.source, match: best, alternatives: outcome.alternatives)
            switch input.confidence.band(for: best.confidence) {
            case .automatic:
                sides[target]?.automaticAdds.append(add)
            case .review:
                sides[target]?.reviewAdds.append(add)
            case .alternative:
                sides[target]?.unavailable.append(.init(source: row.source, alternatives: [best] + outcome.alternatives))
            }
        }

        return SyncPlan(pairId: input.pairId, createdAt: now, sides: sides, conflicts: conflicts, inSyncCount: inSync)
    }

    // MARK: - Private

    private static func allows(_ direction: SyncDirection, from platform: Platform) -> Bool {
        switch direction {
        case .bidirectional: true
        case .spotifyToApple: platform == .spotify
        case .appleToSpotify: platform == .appleMusic
        }
    }

    private static func planRemoval(
        _ row: PlanRow,
        flag: RemovalFlag,
        input: PlanInput,
        sides: inout [Platform: SyncPlan.Side],
        conflicts: inout [SyncPlan.Conflict]
    ) {
        guard !row.removalKept else { return }

        let removedFrom: Platform
        switch flag {
        case .extraOnDestination:
            return // Only on the target of a one-way seam: it stays there.
        case .removedFromSource:
            removedFrom = input.sourcePlatform
        case .removedFromSpotify:
            removedFrom = .spotify
        case .removedFromAppleMusic:
            removedFrom = .appleMusic
        }

        // One-way seams only follow removals made on their source;
        // changes made on the target stay there.
        if input.direction != .bidirectional && removedFrom != input.sourcePlatform { return }

        switch input.removalPolicy {
        case .keep:
            return
        case .ask:
            conflicts.append(.init(
                key: row.key, track: row.source, removedFrom: removedFrom, noticedAt: row.removalFlaggedAt,
                remaining: track(of: row, on: removedFrom.other), removed: track(of: row, on: removedFrom)
            ))
        case .mirror:
            let removeOn = removedFrom.other
            guard let trackOnTarget = track(of: row, on: removeOn) else { return }
            let guided = removeOn == .appleMusic && !input.appleMusicCanRemove
            sides[removeOn]?.removals.append(.init(track: trackOnTarget, isGuided: guided))
        }
    }

    /// The row's track as identified on `platform`.
    private static func track(of row: PlanRow, on platform: Platform) -> CatalogTrack? {
        if row.source.platform == platform { return row.source }
        guard let id = row.counterpartId else { return nil }
        var track = row.source
        track.platform = platform
        track.id = id
        return track
    }
}
