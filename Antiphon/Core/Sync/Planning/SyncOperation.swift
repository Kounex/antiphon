import Foundation

/// One write to run against a platform: the shared currency of conflict
/// resolution, undo and mirrored removals.
struct SyncOperation: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case add
        case remove
        case move(from: Int, to: Int)
    }

    let kind: Kind
    let platform: Platform
    /// The track as identified on `platform`.
    let track: CatalogTrack
    /// The platform can't do this itself; the person is shown how.
    var isGuided: Bool = false
}

/// What each platform can change in a playlist. Spotify can do everything;
/// Apple Music's remove and reorder are off until proven on a device.
struct PlatformCapabilities: Sendable, Equatable {
    var appleMusicCanRemove: Bool
    var appleMusicCanReorder: Bool

    static let spotifyOnly = PlatformCapabilities(appleMusicCanRemove: false, appleMusicCanReorder: false)
    static let full = PlatformCapabilities(appleMusicCanRemove: true, appleMusicCanReorder: true)

    /// Current knowledge (D1): Apple Music playlist editing isn't verified yet.
    static let current = spotifyOnly

    func isGuided(_ kind: SyncOperation.Kind, on platform: Platform) -> Bool {
        guard platform == .appleMusic else { return false }
        switch kind {
        case .add: return false
        case .remove: return !appleMusicCanRemove
        case .move: return !appleMusicCanReorder
        }
    }
}
