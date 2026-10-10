import Foundation

/// How a seam's tracks stand, for the sync card's health bar and pills.
struct SeamCounts: Hashable, Sendable {
    var synced: Int
    var review: Int
    var missing: Int
    var total: Int
    /// Tracks that hit an error (not an availability problem).
    var failed: Int = 0

    static let empty = SeamCounts(synced: 0, review: 0, missing: 0, total: 0)

    /// "48 synced, 3 to review, 1 missing"
    var accessibilityValue: String {
        var parts = ["\(synced) synced", "\(review) to review", "\(missing) missing"]
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }
}

extension SeamCounts {
    /// Counts what the seam is responsible for. Differences the person chose
    /// to keep, tracks that only live on a one-way seam's target, and
    /// removals a one-way seam ignores are left out entirely.
    init(tracks: [CachedTrack], direction: SyncDirection) {
        self = .empty
        let isTwoWay = direction == .bidirectional

        for track in tracks {
            if let flag = track.removalFlag {
                guard track.removalKeptAt == nil, flag != .extraOnDestination, isTwoWay else { continue }
                review += 1
                total += 1
                continue
            }
            total += 1
            switch track.effectiveSyncState {
            case .synced, .skipped:
                synced += 1
            case .needsReview:
                review += 1
            case .failed:
                if track.unmatchedPlatform != nil { missing += 1 } else { failed += 1 }
            case .pending, .syncing:
                break
            }
        }
    }
}

/// What a track row shows on its trailing edge and second line.
enum TrackRowState: Hashable, Sendable {
    case synced
    case syncing
    /// Not processed yet.
    case pending
    /// A close match waiting for the person's call.
    case review(confidence: Int, reason: MatchReason?)
    /// Removed on one side of a two-way seam; waiting for an answer.
    case removed(from: Platform)
    /// Not available on the other side. Not an error.
    case missing(String)
    /// Something broke; Antiphon will retry.
    case failed(String)
}

extension TrackRowState {
    init(_ track: CachedTrack) {
        if let flag = track.removalFlag, track.removalKeptAt == nil {
            switch flag {
            case .removedFromSpotify:
                self = .removed(from: .spotify)
                return
            case .removedFromAppleMusic:
                self = .removed(from: .appleMusic)
                return
            case .removedFromSource:
                let source: Platform = track.syncPair?.syncDirection == .appleToSpotify ? .appleMusic : .spotify
                self = .removed(from: source)
                return
            case .extraOnDestination:
                break
            }
        }

        switch track.effectiveSyncState {
        case .synced, .skipped:
            self = .synced
        case .syncing:
            self = .syncing
        case .pending:
            self = .pending
        case .needsReview:
            self = .review(confidence: track.matchConfidence ?? 0, reason: track.matchReason)
        case .failed:
            if let unmatched = track.unmatchedPlatform {
                let platform: Platform = unmatched == .spotify ? .spotify : .appleMusic
                self = .missing(Self.missingText(on: platform, reason: track.unavailableReason, storefront: track.unavailableStorefront))
            } else {
                self = .failed("Couldn't sync this track. Antiphon will try again.")
            }
        }
    }

    /// "Not on Apple Music in Germany" / "Not on Spotify"
    static func missingText(on platform: Platform, reason: UnavailableReason?, storefront: String?) -> String {
        if reason == .regionLocked, let storefront,
           let country = Locale.current.localizedString(forRegionCode: storefront) {
            return "Not on \(platform.rawValue) in \(country)"
        }
        return "Not on \(platform.rawValue)"
    }
}
