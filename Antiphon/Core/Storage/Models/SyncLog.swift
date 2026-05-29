import Foundation
import SwiftData

/// An audit-trail entry recording the outcome of a single sync operation.
///
/// Each `SyncLog` is owned by a `SyncPair` and captures how many tracks were
/// added, removed, matched, and failed during the sync.
@Model
final class SyncLog {
    var id: UUID
    var timestamp: Date
    var action: SyncAction
    var result: SyncResultStatus?
    var tracksAdded: Int
    var tracksRemoved: Int
    var tracksFailed: Int
    var tracksMatched: Int
    var details: String?
    var syncPair: SyncPair?

    init(
        action: SyncAction,
        result: SyncResultStatus = .success,
        tracksAdded: Int = 0,
        tracksRemoved: Int = 0,
        tracksFailed: Int = 0,
        tracksMatched: Int = 0,
        details: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.action = action
        self.result = result
        self.tracksAdded = tracksAdded
        self.tracksRemoved = tracksRemoved
        self.tracksFailed = tracksFailed
        self.tracksMatched = tracksMatched
        self.details = details
    }

    /// Resolved result — infers status from the details text for legacy rows
    /// that were written before the `result` field existed.
    var effectiveResult: SyncResultStatus {
        if let result { return result }
        if let details {
            if details.hasPrefix("Sync failed") || details.hasPrefix("Safety threshold") {
                return .failed
            }
            if details.hasPrefix("Sync interrupted") {
                return .partial
            }
        }
        return .success
    }

    /// A successful sync that produced no track additions, removals, or failures.
    var isNoOp: Bool {
        effectiveResult == .success && tracksAdded == 0 && tracksRemoved == 0 && tracksFailed == 0
    }
    
    /// Whether this log represents a failed sync operation.
    var isFailed: Bool {
        effectiveResult == .failed
    }
}

// MARK: - SyncAction

/// The type of sync operation that was performed.
enum SyncAction: String, Codable {
    case initialSync
    case deltaSync
    case manualSync
    case monitorSync
    case fullRebuild

    var label: String {
        switch self {
        case .initialSync: return "Initial Sync"
        case .deltaSync: return "Delta Sync"
        case .manualSync: return "Manual Sync"
        case .monitorSync: return "Monitor Sync"
        case .fullRebuild: return "Full Rebuild"
        }
    }

    var icon: String {
        switch self {
        case .initialSync: return "arrow.triangle.2.circlepath.circle"
        case .deltaSync: return "arrow.triangle.2.circlepath"
        case .manualSync: return "hand.tap"
        case .monitorSync: return "eye"
        case .fullRebuild: return "arrow.clockwise.square"
        }
    }
}
