import AntiphonDesign
import SwiftUI

/// Maps app values onto design-system inputs, in one place.
@MainActor
enum SeamPresentation {
    static func service(_ platform: Platform) -> MusicService {
        platform == .spotify ? .spotify : .appleMusic
    }

    static func direction(_ direction: SyncDirection) -> SeamDirection {
        direction == .bidirectional ? .twoWay : .oneWay
    }

    /// Source on the leading side; Spotify leads in a two-way seam.
    static func covers(_ seam: SeamSummary, size: CGFloat) -> (CoverArt, CoverArt) {
        let leading = seam.side(seam.source)
        let trailing = seam.side(seam.source.other)
        return (
            CoverArt(url: leading.artworkURL, seed: seam.name, size: size, service: service(leading.platform)),
            CoverArt(url: trailing.artworkURL, seed: seam.name, size: size, service: service(trailing.platform))
        )
    }

    static func health(_ counts: SeamCounts) -> SeamHealth {
        SeamHealth(synced: counts.synced, review: counts.review, missing: counts.missing, total: counts.total)
    }

    static func trackState(_ state: TrackRowState) -> AntiphonDesign.TrackRow.State {
        switch state {
        case .synced: .synced
        case .syncing: .syncing
        case .pending: .pending
        case .review(let confidence, _): .review(confidence: confidence)
        case .removed: .removed
        case .missing: .missing
        case .failed: .failed
        }
    }

    /// The row's second line: artist and album normally; the match or the
    /// reason otherwise.
    static func trackDetail(_ track: SeamTrack) -> String {
        switch track.state {
        case .review(let confidence, let reason):
            return "\(track.artist) · \(confidence)% match\(reason.map { ", \(reasonPhrase($0))" } ?? "")"
        case .removed(let platform):
            return "Removed on \(platform.rawValue)"
        case .missing(let text), .failed(let text):
            return text
        default:
            if track.isNew { return "\(track.artist) · added recently" }
            return [track.artist, track.album].compactMap { $0 }.joined(separator: " · ")
        }
    }

    static func reasonPhrase(_ reason: MatchReason) -> String {
        switch reason {
        case .isrc: "ISRC match"
        case .titleArtistDuration: "same title and length"
        case .versionDifference: "different version"
        case .titleOnly: "title only"
        case .manual: "chosen by you"
        }
    }
}
