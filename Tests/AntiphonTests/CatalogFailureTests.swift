import Foundation
import MusicKit
import Testing
@testable import Antiphon

@Suite("Catalog failures while planning")
struct CatalogFailureTests {

    @Test("Problems that affect every track stop the preview with a clear reason")
    func stoppers() {
        #expect(CatalogFailure.classify(MusicTokenRequestError.developerTokenRequestFailed)
                == .stop("Antiphon can't reach the Apple Music catalog right now. Your playlists are fine; try again in a few minutes."))
        #expect(CatalogFailure.classify(MusicTokenRequestError.privacyAcknowledgementRequired)
                == .stop("Open the Music app once and accept Apple's privacy notice, then try again."))
        #expect(CatalogFailure.classify(MusicTokenRequestError.userNotSignedIn)
                == .stop("Sign in to Apple Music in Settings › Music, then try again."))
        #expect(CatalogFailure.classify(AppleMusicError.notAuthorized)
                == .stop("Antiphon can't reach Apple Music. Allow access in Settings › Antiphon."))
        #expect(CatalogFailure.classify(SpotifyAPIError.httpError(statusCode: 401, body: nil))
                == .stop("Spotify signed you out. Sign in again in Settings, then try again."))
        #expect(CatalogFailure.classify(SpotifyAPIError.rateLimited)
                == .stop("Spotify is busy. Try again in a minute."))
        #expect(CatalogFailure.classify(URLError(.notConnectedToInternet))
                == .stop("You're offline. Connect to the internet and try again."))
        #expect(CatalogFailure.classify(CancellationError()) == .cancelled)
    }

    @Test("A one-off failure skips just that track")
    func skips() {
        #expect(CatalogFailure.classify(SpotifyAPIError.httpError(statusCode: 404, body: nil)) == .skipTrack)
        #expect(CatalogFailure.classify(SpotifyAPIError.invalidResponse) == .skipTrack)
        #expect(CatalogFailure.classify(URLError(.timedOut)) == .skipTrack)
    }

    @Test("Skipped tracks are mentioned and checked next time")
    func uncheckedNote() {
        #expect(PlanCopy.uncheckedNote(0) == nil)
        #expect(PlanCopy.uncheckedNote(1) == "1 track couldn't be checked right now. Antiphon checks it on the next sync.")
        #expect(PlanCopy.uncheckedNote(3) == "3 tracks couldn't be checked right now. Antiphon checks them on the next sync.")
    }
}
