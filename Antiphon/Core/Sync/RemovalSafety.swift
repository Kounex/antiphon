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
}
