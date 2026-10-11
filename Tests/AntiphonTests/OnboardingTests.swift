import Foundation
import Testing
@testable import Antiphon

@Suite("Twins found")
struct TwinSuggesterTests {
    private func playlist(_ name: String, _ platform: Platform, blocked: Bool = false) -> LibraryPlaylist {
        LibraryPlaylist(platform: platform, id: "\(platform.rawValue)-\(name)", name: name, trackCount: 10, artworkURL: nil,
                        detail: "", isEditable: !blocked, blockedReason: blocked ? "Made by Spotify." : nil, isOwn: !blocked)
    }

    @Test("Names pair up: same name, a word that starts the other, never twice")
    func pairs() {
        let spotify = [playlist("Late Night Drive", .spotify), playlist("Run Club", .spotify), playlist("Garden Sundays", .spotify),
                       playlist("Discover Weekly", .spotify, blocked: true), playlist("Road Trip Lisbon", .spotify)]
        let apple = [playlist("Late Night Drive", .appleMusic), playlist("Running", .appleMusic), playlist("Garden Sundays", .appleMusic),
                     playlist("Discover Weekly", .appleMusic), playlist("Vinyl Rips", .appleMusic)]
        let pairs = TwinSuggester.candidates(spotify: spotify, appleMusic: apple, linked: [])
        #expect(pairs.map { "\($0.spotify.name)|\($0.appleMusic.name)" } == ["Late Night Drive|Late Night Drive", "Garden Sundays|Garden Sundays",
                                                                               "Run Club|Running"])
        #expect(TwinSuggester.candidates(spotify: spotify, appleMusic: apple, linked: ["Spotify-Late Night Drive"]).count == 2)
    }

    @Test("Name similarity counts a word that begins another")
    func similarity() {
        #expect(TwinSuggester.nameScore("Run Club", "Running") == 0.5)
        #expect(TwinSuggester.nameScore("Late Night Drive", "late night drive") == 1)
        #expect(TwinSuggester.nameScore("Gym", "Garden Sundays") == 0)
    }

    @Test("Each pair says why, and likely pairs are checked")
    func suggestions() {
        let pair = TwinSuggester.Pair(spotify: playlist("Garden Sundays", .spotify), appleMusic: playlist("Garden Sundays", .appleMusic))
        let same = TwinSuggester.suggestion(pair, shared: 8, spotifyCount: 10, appleCount: 9)
        #expect(same.detail == "Same name · 80% same")
        #expect(same.isChecked)
        let renamed = TwinSuggester.Pair(spotify: playlist("Run Club", .spotify), appleMusic: playlist("Running", .appleMusic))
        let different = TwinSuggester.suggestion(renamed, shared: 37, spotifyCount: 50, appleCount: 40)
        #expect(different.detail == "Different names · 74% same")
        #expect(different.title == "Run Club ↔ Running")
        let low = TwinSuggester.suggestion(pair, shared: 3, spotifyCount: 8, appleCount: 5)
        #expect(low.detail == "Same name · 38% same")
        #expect(!low.isChecked)
        #expect(TwinSuggester.suggestion(pair, shared: nil, spotifyCount: 8, appleCount: 5).detail == "Same name")
    }

    @Test("What's left without a twin")
    func rest() {
        #expect(TwinSuggester.restLine(spotify: 37, appleMusic: 19)
                == "37 other Spotify playlists and 19 on Apple Music have no twin. You can add them from Library.")
        #expect(TwinSuggester.restLine(spotify: 1, appleMusic: 0) == "1 other Spotify playlist has no twin. You can add it from Library.")
        #expect(TwinSuggester.restLine(spotify: 0, appleMusic: 0) == nil)
        #expect(TwinSuggester.headline(4) == "4 playlists already have a twin")
        #expect(TwinSuggester.headline(1) == "1 playlist already has a twin")
        #expect(TwinSuggester.headline(0) == "No twins found yet")
    }

    @Test("Two-way seams from onboarding ask before removing, unless you chose to mirror")
    func removalPolicy() {
        #expect(TwinSuggester.removalPolicy(for: .keep) == .ask)
        #expect(TwinSuggester.removalPolicy(for: .mirror) == .mirror)
    }
}
