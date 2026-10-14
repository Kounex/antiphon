import Testing
@testable import Antiphon

@Suite("Spotify client ID check")
struct SpotifyClientIDTests {
    private let id = "3f2a9c0e8b7d41f6a5c2e9d0b1f84a7c"

    @Test func acceptsA32CharacterHexID() {
        #expect(SpotifyClientID.check(id) == .valid(id))
    }

    @Test func trimsWhitespaceAndNewlinesFromAPaste() {
        #expect(SpotifyClientID.check("  \(id)\n") == .valid(id))
    }

    @Test func lowercasesSoTheSavedIDMatchesSpotifys() {
        #expect(SpotifyClientID.check(id.uppercased()) == .valid(id))
    }

    @Test func emptyIsNotAnError() {
        #expect(SpotifyClientID.check("") == .empty)
        #expect(SpotifyClientID.check("  \n") == .empty)
    }

    @Test func wrongLengthOrCharactersIsInvalid() {
        #expect(SpotifyClientID.check(String(id.dropLast())) == .invalid)
        #expect(SpotifyClientID.check(id + "a") == .invalid)
        #expect(SpotifyClientID.check("antiphon://spotify-callback") == .invalid)
        #expect(SpotifyClientID.check(String(id.dropLast()) + "g") == .invalid)
    }

    @Test func picksTheIDOutOfACopiedLabel() {
        #expect(SpotifyClientID.check("Client ID \(id)") == .valid(id))
    }

    @Test func invalidMessageSaysWhatToCopy() {
        #expect(SpotifyClientID.invalidMessage.contains("32"))
        #expect(SpotifyClientID.invalidMessage.contains("Client ID"))
    }
}
