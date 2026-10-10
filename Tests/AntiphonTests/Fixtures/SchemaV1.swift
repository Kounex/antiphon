import Foundation
import SwiftData
@testable import Antiphon

/// Frozen copy of the stored properties of the models shipped in 1.2.4
/// (before the redesign). Used only to write a store the way existing
/// installs have it, so migration tests open a real V1 file.
enum V1 {
    @Model
    final class SyncPair {
        @Attribute(.unique) var id: UUID
        var spotifyPlaylistId: String
        var spotifyPlaylistName: String
        var spotifySnapshotId: String?
        var spotifyImageURL: String?
        var appleMusicPlaylistId: String
        var appleMusicPlaylistName: String
        var appleMusicImageURL: String?
        var isMonitored: Bool
        var syncDirection: SyncDirection
        var lastSyncedAt: Date?
        var lastSyncResult: SyncResultStatus?
        var lastSyncMessage: String?
        var lastInterruptedAt: Date?
        var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \V1.CachedTrack.syncPair)
        var cachedTracks: [V1.CachedTrack] = []
        @Relationship(deleteRule: .cascade, inverse: \V1.SyncLog.syncPair)
        var syncLogs: [V1.SyncLog] = []

        init(direction: SyncDirection) {
            id = UUID()
            spotifyPlaylistId = "sp-1"
            spotifyPlaylistName = "Late Night Drive"
            appleMusicPlaylistId = "p.am-1"
            appleMusicPlaylistName = "Late Night Drive"
            isMonitored = true
            syncDirection = direction
            createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        }
    }

    @Model
    final class CachedTrack {
        @Attribute(.unique) var id: UUID
        var isrc: String
        var title: String
        var artist: String
        var albumName: String?
        var artworkURL: String?
        var durationMs: Int?
        var spotifyTrackUri: String?
        var appleMusicTrackId: String?
        var addedAt: Date
        var source: TrackSource
        var syncState: TrackSyncState?
        var lastSyncAttempt: Date?
        var retryCount: Int = 0
        var removalFlag: RemovalFlag?
        var removalFlaggedAt: Date?
        var removalKeptAt: Date?
        var unmatchedPlatform: UnmatchedPlatform?
        var syncPair: V1.SyncPair?

        init(title: String, isrc: String) {
            id = UUID()
            self.isrc = isrc
            self.title = title
            artist = "Kavinsky"
            addedAt = Date(timeIntervalSince1970: 1_700_000_100)
            source = .both
            syncState = .synced
        }
    }

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
        var syncPair: V1.SyncPair?

        init(added: Int) {
            id = UUID()
            timestamp = Date(timeIntervalSince1970: 1_700_000_200)
            action = .monitorSync
            result = .success
            tracksAdded = added
            tracksRemoved = 0
            tracksFailed = 0
            tracksMatched = 10
        }
    }
}
