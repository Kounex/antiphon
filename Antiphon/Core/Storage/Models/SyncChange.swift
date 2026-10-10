import Foundation
import SwiftData

/// One write that landed on a platform during a sync run.
///
/// Runs keep their changes so History can show exactly what happened and
/// Undo can build the inverse operations.
@Model
final class SyncChange {
    var id: UUID
    var run: SyncLog?
    /// Where the write landed.
    var platform: Platform
    var kind: ChangeKind
    /// Spotify URI, or Apple Music catalog/library ID.
    var platformTrackId: String
    var isrc: String?
    var title: String
    var artist: String
    var artworkURL: String?
    var fromIndex: Int?
    var toIndex: Int?
    var confidence: Int?
    var reason: MatchReason?
    /// Set by Activity › New tracks "Mark all seen".
    var seenAt: Date?

    init(
        platform: Platform,
        kind: ChangeKind,
        track: CatalogTrack,
        confidence: Int? = nil,
        reason: MatchReason? = nil,
        fromIndex: Int? = nil,
        toIndex: Int? = nil
    ) {
        self.id = UUID()
        self.platform = platform
        self.kind = kind
        self.platformTrackId = track.id
        self.isrc = track.isrc
        self.title = track.title
        self.artist = track.artist
        self.artworkURL = track.artworkURL
        self.confidence = confidence
        self.reason = reason
        self.fromIndex = fromIndex
        self.toIndex = toIndex
    }
}

enum ChangeKind: String, Codable, Sendable {
    case add
    case remove
    case move
}
