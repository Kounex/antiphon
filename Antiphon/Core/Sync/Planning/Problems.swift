import Foundation
import MusicKit
import SwiftData

/// Turns a sync failure into something the person can act on, or `nil`
/// for temporary trouble that the next sync will get past.
enum ProblemClassifier {
    struct Problem: Equatable, Sendable {
        let kind: ProblemKind
        let platform: Platform?
        let message: String
        let retryAt: Date?
    }

    /// Spotify's rate limit usually clears within minutes.
    static let rateLimitRetry: TimeInterval = 15 * 60

    static func problem(for error: any Error, seamName: String, now: Date = Date()) -> Problem? {
        switch error {
        case is CancellationError:
            return nil
        case SpotifyAuthError.notAuthenticated, SpotifyAuthError.tokenRefreshFailed, SpotifyAuthError.noClientId:
            return Problem(kind: .signedOut, platform: .spotify, message: "Spotify signed you out", retryAt: nil)
        case SpotifyAPIError.httpError(let code, _) where code == 401 || code == 403:
            return Problem(kind: .signedOut, platform: .spotify, message: "Spotify signed you out", retryAt: nil)
        case AppleMusicError.notAuthorized:
            return Problem(kind: .signedOut, platform: .appleMusic, message: "Antiphon can't reach Apple Music", retryAt: nil)
        case SyncError.appleMusicPlaylistNotFound:
            return Problem(kind: .playlistDeleted, platform: .appleMusic, message: "\(seamName) was deleted", retryAt: nil)
        case SyncError.spotifyPlaylistNotFound, SpotifyAPIError.httpError(404, _):
            return Problem(kind: .playlistDeleted, platform: .spotify, message: "\(seamName) was deleted", retryAt: nil)
        case SpotifyAPIError.rateLimited:
            return Problem(kind: .rateLimited, platform: .spotify, message: "Spotify is busy", retryAt: now.addingTimeInterval(rateLimitRetry))
        case is MusicTokenRequestError:
            return Problem(kind: .rateLimited, platform: .appleMusic, message: "Apple Music is busy", retryAt: now.addingTimeInterval(rateLimitRetry))
        default:
            return nil
        }
    }
}

/// Persists problems so the Problems screen and notifications agree.
enum ProblemStore {
    /// Records `problem` once: sign-outs are global, the rest belong to the seam.
    static func record(_ problem: ProblemClassifier.Problem, for pair: SyncPair, in context: ModelContext, now: Date = Date()) {
        let global = problem.kind == .signedOut
        let existing = (try? context.fetch(FetchDescriptor<SyncProblem>(predicate: #Predicate { $0.resolvedAt == nil }))) ?? []
        if let match = existing.first(where: {
            $0.kind == problem.kind && $0.platform == problem.platform && (global ? $0.pair == nil : $0.pair?.id == pair.id)
        }) {
            match.retryAt = problem.retryAt
            match.message = problem.message
            return
        }
        let record = SyncProblem(kind: problem.kind, platform: problem.platform, message: problem.message, retryAt: problem.retryAt)
        record.firstSeenAt = now
        record.pair = global ? nil : pair
        context.insert(record)
    }

    /// A successful sync clears the seam's problems and any sign-out.
    static func resolveAll(for pair: SyncPair, in context: ModelContext, now: Date = Date()) {
        let open = (try? context.fetch(FetchDescriptor<SyncProblem>(predicate: #Predicate { $0.resolvedAt == nil }))) ?? []
        for problem in open where problem.pair == nil || problem.pair?.id == pair.id {
            problem.resolvedAt = now
        }
    }
}
