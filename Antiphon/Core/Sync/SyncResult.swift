import Foundation

/// Represents the outcome of a sync operation for a single SyncPair.
struct SyncResult: Sendable {
    let pairId: UUID
    let status: SyncResultStatus
    let message: String?
    var tracksAdded: Int = 0
    var tracksFlagged: Int = 0
    var tracksFailed: Int = 0
    /// The playlists changed after the preview; nothing was applied.
    var isStale: Bool = false
    /// Titles of the tracks this run added, in the order they landed.
    var addedTitles: [String] = []
    /// How many changes the run recorded, once it ran to its end. `nil` for
    /// a run that failed, was stopped, or found its plan stale.
    var settledChanges: Int?
    /// One cheap look showed neither playlist had changed; nothing was read in full.
    var skippedUnchanged = false
    
    var isSuccess: Bool { status == .success }
    
    init(
        pairId: UUID,
        status: SyncResultStatus,
        message: String? = nil,
        tracksAdded: Int = 0,
        tracksFlagged: Int = 0,
        tracksFailed: Int = 0
    ) {
        self.pairId = pairId
        self.status = status
        self.message = message
        self.tracksAdded = tracksAdded
        self.tracksFlagged = tracksFlagged
        self.tracksFailed = tracksFailed
    }
}
