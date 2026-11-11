import Foundation
import Testing
@testable import Antiphon

@Suite("Spotify client ID invite")
struct SpotifyInviteTests {
    private let id = "0123456789abcdef0123456789abcdef"

    @Test("The link carries the client ID and reads back")
    func roundTrip() throws {
        let link = try #require(SpotifyInvite.link(clientId: id))
        #expect(link.absoluteString == "antiphon://connect?client_id=\(id)")
        #expect(SpotifyInvite.clientId(from: link) == id)
    }

    @Test("Only a real client ID is taken from a link; other links are left alone")
    func rejects() throws {
        #expect(SpotifyInvite.clientId(from: try #require(URL(string: "antiphon://connect?client_id=nope"))) == nil)
        #expect(SpotifyInvite.clientId(from: try #require(URL(string: "antiphon://connect"))) == nil)
        #expect(SpotifyInvite.clientId(from: try #require(URL(string: "antiphon://spotify-callback?code=\(id)"))) == nil)
        #expect(SpotifyInvite.clientId(from: try #require(URL(string: "https://example.com/connect?client_id=\(id)"))) == nil)
        #expect(SpotifyInvite.link(clientId: "not an id") == nil)
    }

    @Test("The message tells the owner's part: add the friend's Spotify email first")
    func message() throws {
        let text = try #require(SpotifyInvite.message(clientId: id))
        #expect(text.contains("antiphon://connect?client_id=\(id)"))
        #expect(text.contains("Users Management"))
        #expect(text.contains("email address of your Spotify account"))
    }
}
