import Foundation

/// Represents the outcome of a sync operation for a single SyncPair.
struct SyncResult: Sendable {
    let pairId: UUID
    let status: SyncResultStatus
    let message: String?
    var tracksAdded: Int = 0
    var tracksFlagged: Int = 0
    var tracksFailed: Int = 0
    
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
