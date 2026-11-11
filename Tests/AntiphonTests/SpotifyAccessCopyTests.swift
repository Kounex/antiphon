import Foundation
import Testing
@testable import Antiphon

@Suite("Spotify access errors in plain words")
struct SpotifyAccessCopyTests {
    private let refusedBody = #"{"error":{"status":403,"message":"Check settings on developer.spotify.com/dashboard, the user may not be registered."}}"#

    @Test func readsSpotifysOwnMessageFromTheErrorBody() {
        #expect(SpotifyAccessCopy.spotifyMessage(fromBody: refusedBody)
                == "Check settings on developer.spotify.com/dashboard, the user may not be registered.")
        #expect(SpotifyAccessCopy.spotifyMessage(fromBody: nil) == nil)
        #expect(SpotifyAccessCopy.spotifyMessage(fromBody: "<html>Bad gateway</html>") == nil)
    }

    /// What Spotify actually sent for an account missing from Users
    /// Management (dev app on the phone, 2026-11-11): plain text, not JSON.
    @Test func readsAPlainTextBodyToo() {
        let body = "The user is not registered for this application. Please check your settings on https://developer.spotify.com/dashboard."
        #expect(SpotifyAccessCopy.spotifyMessage(fromBody: body) == body)
        #expect(SpotifyAccessCopy.spotifyMessage(fromBody: "  \n") == nil)
        #expect(SpotifyAccessCopy.spotifyMessage(fromBody: String(repeating: "x", count: 500)) == nil)
    }

    @Test func refusedAccountSaysWhoHasToFixWhatAndQuotesSpotify() {
        let message = SpotifyAccessCopy.message(for: SpotifyAPIError.httpError(statusCode: 403, body: refusedBody))
        #expect(message.contains("Premium"))
        #expect(message.contains("Users Management"))
        #expect(message.contains("the user may not be registered"))
        #expect(!message.contains("signed you out"))
    }

    @Test func refusedWithoutABodyStillExplains() {
        let message = SpotifyAccessCopy.message(for: SpotifyAPIError.httpError(statusCode: 403, body: nil))
        #expect(message.contains("Users Management"))
        #expect(!message.contains("Spotify said"))
    }

    @Test func refusedIsRecognised() {
        #expect(SpotifyAccessCopy.isRefused(SpotifyAPIError.httpError(statusCode: 403, body: refusedBody)))
        #expect(!SpotifyAccessCopy.isRefused(SpotifyAPIError.httpError(statusCode: 500, body: nil)))
        #expect(!SpotifyAccessCopy.isRefused(SpotifyAPIError.rateLimited))
    }

    @Test func signedOutAsksToConnectAgain() {
        for error: any Error in [SpotifyAuthError.notAuthenticated, SpotifyAuthError.tokenRefreshFailed,
                                 SpotifyAPIError.httpError(statusCode: 401, body: nil)] {
            #expect(SpotifyAccessCopy.message(for: error).contains("Connect"))
        }
    }

    @Test func missingClientIDPointsToSettings() {
        #expect(SpotifyAccessCopy.message(for: SpotifyAuthError.noClientId).contains("client ID"))
    }

    @Test func busyAndOffline() {
        #expect(SpotifyAccessCopy.message(for: SpotifyAPIError.rateLimited).contains("busy"))
        #expect(SpotifyAccessCopy.message(for: URLError(.notConnectedToInternet)).contains("offline"))
    }

    @Test func otherServerErrorsQuoteTheStatus() {
        let message = SpotifyAccessCopy.message(for: SpotifyAPIError.httpError(statusCode: 502, body: nil))
        #expect(message.contains("502"))
    }

    @Test func unreadableReplyNamesTheField() throws {
        struct Needs: Decodable { let snapshot_id: String }
        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(Needs.self, from: Data(#"{"name":"x"}"#.utf8))
        }
        let message = SpotifyAccessCopy.message(for: error)
        #expect(message.contains("couldn't read"))
        #expect(message.contains("snapshot_id"))
    }
}

@MainActor
@Suite("New seam: why playlists didn't load")
struct NewSeamLoadErrorTests {
    struct RefusingLibrary: LibraryService {
        let error: any Error
        func playlists(on platform: Platform) async throws -> [LibraryPlaylist] { throw error }
        func tracks(of playlist: LibraryPlaylist) async throws -> [CatalogTrack] { [] }
    }

    @Test func spotifyRefusalIsShownNotHidden() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let model = NewSeamModel(
            library: RefusingLibrary(error: SpotifyAPIError.httpError(
                statusCode: 403, body: #"{"error":{"status":403,"message":"the user may not be registered."}}"#)),
            seams: SwiftDataSeamRepository(modelContainer: container),
            preferences: AppPreferences(defaults: UserDefaults(suiteName: "NewSeamLoadErrorTests")!))
        await model.loadPlaylists()
        let error = try #require(model.loadError)
        #expect(error.contains("Users Management"))
        #expect(error.contains("the user may not be registered"))
    }
}
