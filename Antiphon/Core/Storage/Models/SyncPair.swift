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

    // MARK: - Rules (redesign; all optional or defaulted for migration)

    /// What happens when a track is removed on one side. `nil` means the
    /// direction's safe default — see `effectiveRemovalPolicy`.
    var removalPolicy: RemovalPolicy?
    /// Minutes between monitoring checks. `nil` uses the app-wide default;
    /// `0` means "Only when I ask".
    var monitorIntervalMinutes: Int?
    /// Which side's order wins. `nil` means the source side.
    var orderSource: Platform?
    /// `nil` means `.sourceOrder`.
    var newTrackPlacement: TrackPlacement?
    var notifyNewTracks: Bool = false
    /// Set by "Pause this seam": no syncs run until cleared.
    var pausedAt: Date?
    var spotifyCreatedByAntiphon: Bool = false
    var appleMusicCreatedByAntiphon: Bool = false
    /// Drives the "New" filter on seam detail.
    var lastViewedAt: Date?
    /// The direction changed: the next sync realigns from scratch (like a
    /// first sync) instead of reading the old cache as removals.
    var needsRebuild: Bool = false

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \CachedTrack.syncPair)
    var cachedTracks: [CachedTrack] = []

    @Relationship(deleteRule: .cascade, inverse: \SyncLog.syncPair)
    var syncLogs: [SyncLog] = []

    @Relationship(deleteRule: .cascade, inverse: \SyncProblem.pair)
    var problems: [SyncProblem] = []

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

// MARK: - Rule Helpers

extension SyncPair {
    var isTwoWay: Bool { syncDirection == .bidirectional }

    /// Nothing is removed by default: one-way seams keep removed tracks,
    /// two-way seams turn a removal into a question.
    var effectivePlacement: TrackPlacement { newTrackPlacement ?? .sourceOrder }

    /// Whether Antiphon places new tracks on `platform`. Apple Music only lets
    /// apps reorder playlists they created; elsewhere tracks go at the end.
    func canPlace(on platform: Platform) -> Bool {
        guard effectivePlacement == .sourceOrder else { return false }
        return platform == .spotify || appleMusicCreatedByAntiphon
    }

    var effectiveRemovalPolicy: RemovalPolicy {
        removalPolicy ?? (isTwoWay ? .ask : .keep)
    }

    var isPaused: Bool { pausedAt != nil }
}

/// What a seam does when a track disappears from one of its playlists.
enum RemovalPolicy: String, Codable, CaseIterable, Sendable {
    /// Leave the other playlist alone.
    case keep
    /// Remove it from the other playlist too (opt-in, logged, undoable).
    case mirror
    /// Ask first. The default for two-way seams.
    case ask
}

/// Where tracks Antiphon adds are placed in the target playlist.
enum TrackPlacement: String, Codable, Sendable {
    /// After the same neighbour as on the other side. The default.
    case sourceOrder
    case end
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
        case .partial: return "flag.fill"
        case .failed: return "exclamationmark.circle.fill"
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
