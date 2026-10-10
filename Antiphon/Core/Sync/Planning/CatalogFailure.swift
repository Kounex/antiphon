import Foundation
import MusicKit

/// What a catalog lookup error means for a preview in progress.
///
/// Errors that would hit every track (no developer token, signed out,
/// offline, rate limited) stop the preview with a reason the person can act
/// on. Anything else only skips that track; it's checked on the next sync.
enum CatalogFailure: Equatable {
    case stop(String)
    case skipTrack
    case cancelled

    static func classify(_ error: any Error) -> CatalogFailure {
        if error is CancellationError { return .cancelled }

        if let token = error as? MusicTokenRequestError {
            switch token {
            case .privacyAcknowledgementRequired:
                return .stop("Open the Music app once and accept Apple's privacy notice, then try again.")
            case .userNotSignedIn, .userTokenRevoked:
                return .stop("Sign in to Apple Music in Settings › Music, then try again.")
            case .permissionDenied:
                return .stop("Antiphon can't reach Apple Music. Allow access in Settings › Antiphon.")
            default:
                return .stop("Antiphon can't reach the Apple Music catalog right now. Your playlists are fine; try again in a few minutes.")
            }
        }
        if case AppleMusicError.notAuthorized = error {
            return .stop("Antiphon can't reach Apple Music. Allow access in Settings › Antiphon.")
        }
        if let spotify = error as? SpotifyAPIError {
            switch spotify {
            case .rateLimited: return .stop("Spotify is busy. Try again in a minute.")
            case .httpError(let code, _) where code == 401 || code == 403:
                return .stop("Spotify signed you out. Sign in again in Settings, then try again.")
            default: return .skipTrack
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .stop("You're offline. Connect to the internet and try again.")
            default: return .skipTrack
            }
        }
        return .skipTrack
    }
}

/// Thrown by the planner when a lookup error makes the whole preview impossible.
struct PlanningStopped: Error, Equatable {
    let message: String
}
