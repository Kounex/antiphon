import Foundation
import SwiftData

/// The primary SwiftData model that links a Spotify playlist to an Apple Music playlist.
///
/// Each `SyncPair` tracks the identifiers, sync configuration, and current state
/// for a single playlist pairing. It owns cascading relationships to `CachedTrack`
/// and `SyncLog` for delta calculation and audit history.
@Model
final class SyncPair {
    @Attribute(.unique) var id: UUID

    // MARK: - Spotify Side

    var spotifyPlaylistId: String
    var spotifyPlaylistName: String
    var spotifySnapshotId: String?
    var spotifyImageURL: String?

    // MARK: - Apple Music Side

    var appleMusicPlaylistId: String
    var appleMusicPlaylistName: String
    var appleMusicImageURL: String?

    // MARK: - Configuration

    var isMonitored: Bool
    var syncDirection: SyncDirection

    // MARK: - State

    var lastSyncedAt: Date?
    var lastSyncResult: SyncResultStatus?
    var lastSyncMessage: String?
    var lastInterruptedAt: Date?
    var createdAt: Date

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \CachedTrack.syncPair)
    var cachedTracks: [CachedTrack] = []

    @Relationship(deleteRule: .cascade, inverse: \SyncLog.syncPair)
    var syncLogs: [SyncLog] = []

    init(
        spotifyPlaylistId: String,
        spotifyPlaylistName: String,
        appleMusicPlaylistId: String,
        appleMusicPlaylistName: String,
        syncDirection: SyncDirection = .bidirectional
    ) {
        self.id = UUID()
        self.spotifyPlaylistId = spotifyPlaylistId
        self.spotifyPlaylistName = spotifyPlaylistName
        self.appleMusicPlaylistId = appleMusicPlaylistId
        self.appleMusicPlaylistName = appleMusicPlaylistName
        self.isMonitored = false
        self.syncDirection = syncDirection
        self.createdAt = Date()
    }
}

// MARK: - SyncDirection

/// Describes which direction tracks flow between platforms.
enum SyncDirection: String, Codable, CaseIterable {
    case bidirectional = "Bidirectional"
    case spotifyToApple = "Spotify → Apple Music"
    case appleToSpotify = "Apple Music → Spotify"

    var icon: String {
        switch self {
        case .bidirectional: return "arrow.left.arrow.right"
        case .spotifyToApple: return "arrow.right"
        case .appleToSpotify: return "arrow.left"
        }
    }
}

// MARK: - SyncResultStatus

/// The outcome status of a sync operation.
enum SyncResultStatus: String, Codable {
    case success
    case partial
    case failed
    case inProgress

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .inProgress: return "arrow.triangle.2.circlepath"
        }
    }

    /// Asset catalog color name for this status.
    var color: String {
        switch self {
        case .success: return "SyncSuccess"
        case .partial: return "SyncWarning"
        case .failed: return "SyncError"
        case .inProgress: return "SyncProgress"
        }
    }
}
