import Foundation
import SwiftData

/// A local snapshot of a track used for ISRC-based delta calculation.
///
/// Each `CachedTrack` stores the ISRC and platform-specific identifiers so the
/// sync engine can determine which tracks were added or removed since the last sync.
@Model
final class CachedTrack {
    @Attribute(.unique) var id: UUID

    /// International Standard Recording Code — the universal track identifier.
    var isrc: String
    var title: String
    var artist: String
    var albumName: String?
    var artworkURL: String?
    var durationMs: Int?

    // MARK: - Platform-Specific IDs

    var spotifyTrackUri: String?
    var appleMusicTrackId: String?

    // MARK: - State

    var addedAt: Date
    var source: TrackSource
    /// The current sync processing state for this track.
    /// Optional for SwiftData migration — nil treated as .synced.
    var syncState: TrackSyncState?
    
    /// When this track was last attempted for matching.
    var lastSyncAttempt: Date?
    
    /// How many times matching has been attempted (max 3 retries).
    var retryCount: Int = 0

    /// Set when the track is detected as removed on one platform but not the other.
    var removalFlag: RemovalFlag?
    var removalFlaggedAt: Date?

    /// Set when the sync engine failed to find this track on the target platform.
    var unmatchedPlatform: UnmatchedPlatform?

    // MARK: - Relationship

    var syncPair: SyncPair?

    // MARK: - Computed Helpers

    /// Non-optional sync state — treats nil (legacy data) as .synced.
    var effectiveSyncState: TrackSyncState {
        get { syncState ?? .synced }
        set { syncState = newValue }
    }

    /// Source dot status — shows whether we've loaded this track from the source.
    /// Green = in cache (loaded from source), Yellow = removed from source, Gray = destination-only extra.
    /// Never red.
    var sourceDotStatus: PlatformSyncStatus {
        let direction = syncPair?.syncDirection ?? .bidirectional
        
        // Yellow: track was removed from the source platform
        switch direction {
        case .spotifyToApple:
            if removalFlag == .removedFromSpotify || removalFlag == .removedFromSource { return .flagged }
        case .appleToSpotify:
            if removalFlag == .removedFromAppleMusic || removalFlag == .removedFromSource { return .flagged }
        case .bidirectional:
            if removalFlag == .removedFromSpotify || removalFlag == .removedFromAppleMusic || removalFlag == .removedFromSource { return .flagged }
        }
        
        // Gray: this track only exists on the destination, not the source
        if removalFlag == .extraOnDestination { return .pending }
        
        // Green: track is in the cache = it was loaded from the source
        return .synced
    }

    /// Target dot status — shows the sync result for the target platform.
    /// Gray = not yet synced, Green = synced, Yellow = removed from target / extra on destination,
    /// Red = failed to match.
    var targetDotStatus: PlatformSyncStatus {
        let direction = syncPair?.syncDirection ?? .bidirectional
        
        // Yellow: track was removed from the target platform
        switch direction {
        case .spotifyToApple:
            if removalFlag == .removedFromAppleMusic { return .flagged }
        case .appleToSpotify:
            if removalFlag == .removedFromSpotify { return .flagged }
        case .bidirectional:
            break // handled below
        }
        
        // Yellow: extra on destination (exists on target but not source)
        if removalFlag == .extraOnDestination { return .flagged }
        
        // Based on sync processing state
        switch effectiveSyncState {
        case .pending:
            return .pending     // Gray — not yet synced
        case .syncing:
            return .syncing     // Animated — currently being matched
        case .synced, .skipped:
            // Check if it was actually matched
            if unmatchedPlatform != nil { return .unmatched } // Red
            return .synced      // Green — successfully synced
        case .failed:
            return .unmatched   // Red — failed to match
        }
    }

    /// Whether this track needs attention (unmatched, flagged, or mismatched).
    var needsAttention: Bool {
        unmatchedPlatform != nil || removalFlag != nil
    }

    /// Dynamically resolved description for the removal flag based on the track's platform details.
    var removalDescription: String? {
        guard let flag = removalFlag else { return nil }
        
        let direction = syncPair?.syncDirection ?? .bidirectional
        
        switch flag {
        case .removedFromSpotify:
            return "Removed from Spotify — still on Apple Music"
        case .removedFromAppleMusic:
            return "Removed from Apple Music — still on Spotify"
        case .extraOnDestination:
            if appleMusicTrackId != nil && spotifyTrackUri == nil {
                return "Only on Apple Music — not on Spotify"
            } else if spotifyTrackUri != nil && appleMusicTrackId == nil {
                return "Only on Spotify — not on Apple Music"
            } else {
                return "Only on destination — not in source playlist"
            }
        case .removedFromSource:
            if direction == .appleToSpotify {
                return "Removed from Apple Music — still on Spotify"
            } else if direction == .spotifyToApple {
                return "Removed from Spotify — still on Apple Music"
            } else {
                if spotifyTrackUri != nil && appleMusicTrackId == nil {
                    return "Removed from Apple Music — still on Spotify"
                } else if appleMusicTrackId != nil && spotifyTrackUri == nil {
                    return "Removed from Spotify — still on Apple Music"
                } else {
                    return "Removed from source — still on destination"
                }
            }
        }
    }

    init(
        isrc: String,
        title: String,
        artist: String,
        albumName: String? = nil,
        artworkURL: String? = nil,
        durationMs: Int? = nil,
        spotifyTrackUri: String? = nil,
        appleMusicTrackId: String? = nil,
        source: TrackSource,
        syncState: TrackSyncState = .synced
    ) {
        self.id = UUID()
        self.isrc = isrc
        self.title = title
        self.artist = artist
        self.albumName = albumName
        self.artworkURL = artworkURL
        self.durationMs = durationMs
        self.spotifyTrackUri = spotifyTrackUri
        self.appleMusicTrackId = appleMusicTrackId
        self.addedAt = Date()
        self.source = source
        self.syncState = syncState
        self.retryCount = 0
    }
}

// MARK: - TrackSource

/// Indicates which platform(s) a cached track originated from.
enum TrackSource: String, Codable {
    case spotify
    case appleMusic
    case both
}

// MARK: - RemovalFlag

/// Flags a track that has a mismatch between the source and destination playlists.
enum RemovalFlag: String, Codable {
    case removedFromSpotify
    case removedFromAppleMusic
    /// Track exists on destination but not on source — needs user review
    case extraOnDestination
    /// Track was removed from the source playlist
    case removedFromSource

    var description: String {
        switch self {
        case .removedFromSpotify:
            return "Removed from Spotify — still on Apple Music"
        case .removedFromAppleMusic:
            return "Removed from Apple Music — still on Spotify"
        case .extraOnDestination:
            return "Only on destination — not in source playlist"
        case .removedFromSource:
            return "Removed from source — still on destination"
        }
    }
    
    var icon: String {
        switch self {
        case .removedFromSpotify, .removedFromAppleMusic:
            return "minus.circle.fill"
        case .extraOnDestination:
            return "exclamationmark.triangle.fill"
        case .removedFromSource:
            return "arrow.uturn.backward.circle.fill"
        }
    }
}

// MARK: - UnmatchedPlatform

/// Marks which target platform a track could not be found on during sync.
enum UnmatchedPlatform: String, Codable {
    case spotify
    case appleMusic

    var description: String {
        switch self {
        case .spotify: return "Not found on Spotify"
        case .appleMusic: return "Not found on Apple Music"
        }
    }
}

// MARK: - Platform Sync Status

/// The sync state of a track on a single platform.
enum PlatformSyncStatus {
    case synced     // green — confirmed on this platform
    case unmatched  // red — failed to find match
    case flagged    // yellow — removal detected, pending review
    case pending    // gray — not yet processed
    case syncing    // animated — currently being matched
    case unknown    // gray — no data
}

// MARK: - Track Sync State

/// The processing state of a track during a sync operation.
enum TrackSyncState: String, Codable {
    case pending    // Waiting to be matched
    case syncing    // Currently being matched
    case synced     // Successfully matched and synced
    case failed     // Failed to match
    case skipped    // Skipped (e.g. already exists on both sides)
}
