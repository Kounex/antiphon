import Foundation

/// Stops a sync when a read looks broken: most of a playlist suddenly
/// missing usually means the platform returned too little, not that the
/// person removed it all.
enum RemovalSafety {
    /// Below this many new removals the share doesn't matter: removing one
    /// or two songs from a small playlist is ordinary.
    static let minimumRemovals = 3

    /// Rows flagged during this sync. Questions already open from earlier
    /// syncs and kept differences aren't new.
    static func newRemovals(in rows: [CachedTrack], since start: Date) -> Int {
        rows.filter { row in
            guard let flag = row.removalFlag, row.removalKeptAt == nil,
                  let flaggedAt = row.removalFlaggedAt, flaggedAt >= start else { return false }
            return flag == .removedFromSpotify || flag == .removedFromAppleMusic || flag == .removedFromSource
        }.count
    }

    static func shouldStop(_ rows: [CachedTrack], since start: Date,
                           threshold: Double = AppConstants.Sync.safetyThresholdPercentage) -> Bool {
        let removals = newRemovals(in: rows, since: start)
        guard removals >= minimumRemovals, !rows.isEmpty else { return false }
        return Double(removals) / Double(rows.count) > threshold
    }

    /// Removal state of each row before a sync flags anything. When the
    /// check stops the sync, `restore` puts it back: the flags were never
    /// acted on, and left in place they wouldn't count as new next time,
    /// so a second broken read would pass the check.
    struct Snapshot {
        private let rows: [(row: CachedTrack, source: TrackSource, flag: RemovalFlag?, flaggedAt: Date?, keptAt: Date?,
                            state: TrackSyncState?)]

        init(_ rows: [CachedTrack]) {
            self.rows = rows.map { ($0, $0.source, $0.removalFlag, $0.removalFlaggedAt, $0.removalKeptAt, $0.syncState) }
        }

        /// Restores the rows still in `current` (pruned rows are deleted).
        func restore(_ current: [CachedTrack]) {
            let live = Set(current.map(ObjectIdentifier.init))
            for saved in rows where live.contains(ObjectIdentifier(saved.row)) {
                saved.row.source = saved.source
                saved.row.removalFlag = saved.flag
                saved.row.removalFlaggedAt = saved.flaggedAt
                saved.row.removalKeptAt = saved.keptAt
                saved.row.syncState = saved.state
            }
        }
    }
}
