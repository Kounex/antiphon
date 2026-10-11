import Foundation
import MusicKit
import Testing
@testable import Antiphon

@Suite("Library grid")
struct LibraryGridTests {
    private func playlist(_ name: String, _ platform: Platform, count: Int? = 10, own: Bool = true, blocked: String? = nil) -> LibraryPlaylist {
        LibraryPlaylist(platform: platform, id: "\(platform.rawValue)-\(name)", name: name, trackCount: count, artworkURL: nil,
                        detail: blocked == nil ? "\(count ?? 0) tracks · yours" : "48 tracks · by Spotify",
                        isEditable: blocked == nil, blockedReason: blocked, isOwn: own)
    }

    private var items: [LibraryItem] {
        let seam = PreviewFixtures.seam("Late Night Drive", direction: .spotifyToApple, monitored: true,
                                        counts: SeamCounts(synced: 1, review: 0, missing: 0, total: 1), checkedMinutesAgo: 1)
        return LibraryGrid.items(
            spotify: [playlist("Road Trip Lisbon", .spotify, count: 112, own: false), playlist("Late Night Drive", .spotify),
                      playlist("Focus Flow", .spotify, count: 48, own: false, blocked: "Made by Spotify.")],
            appleMusic: [playlist("Vinyl Rips", .appleMusic, count: nil), playlist("Late Night Drive", .appleMusic, count: nil)],
            seams: [seam]
        )
    }

    @Test("Playlists in a seam are known on both sides")
    func seamed() {
        let seamed = items.filter { $0.seam != nil }.map(\.id)
        #expect(seamed == ["Spotify:Spotify-Late Night Drive", "Apple Music:Apple Music-Late Night Drive"])
    }

    @Test("The default filter shows playlists with no twin, from both libraries")
    func noTwin() {
        let names = LibraryGrid.visible(items, scope: .both, filter: .noTwin, sort: .library).map(\.playlist.name)
        #expect(names == ["Road Trip Lisbon", "Focus Flow", "Vinyl Rips"])
    }

    @Test("Each filter counts within the chosen library")
    func counts() {
        let both = LibraryGrid.counts(items, scope: .both)
        #expect(both[.noTwin] == 3 && both[.inSeam] == 2 && both[.madeByMe] == 3)
        let spotify = LibraryGrid.counts(items, scope: .spotify)
        #expect(spotify[.noTwin] == 2 && spotify[.inSeam] == 1 && spotify[.madeByMe] == 1)
    }

    @Test("Sorting by name or by size")
    func sorting() {
        let byName = LibraryGrid.visible(items, scope: .both, filter: .noTwin, sort: .name).map(\.playlist.name)
        #expect(byName == ["Focus Flow", "Road Trip Lisbon", "Vinyl Rips"])
        let bySize = LibraryGrid.visible(items, scope: .both, filter: .noTwin, sort: .size).map(\.playlist.name)
        #expect(bySize == ["Road Trip Lisbon", "Focus Flow", "Vinyl Rips"])
    }

    @Test("Each cover says where it stands")
    func details() {
        let byName = Dictionary(items.map { ("\($0.playlist.platform.rawValue) \($0.playlist.name)", $0.detail) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["Spotify Road Trip Lisbon"] == "112 tracks · no twin")
        #expect(byName["Spotify Late Night Drive"] == "Stitched to Apple Music")
        #expect(byName["Apple Music Late Night Drive"] == "Stitched to Spotify")
        #expect(byName["Spotify Focus Flow"] == "48 tracks · by Spotify")
        #expect(byName["Apple Music Vinyl Rips"] == "No twin yet")
    }
}

@Suite("Apple Music ownership")
struct AppleMusicOwnershipTests {
    @Test("Playlists made by the person or Antiphon are theirs; editorial and mixes aren't")
    func kinds() {
        #expect(AppleMusicOwnership.isOwn(kind: nil))
        #expect(AppleMusicOwnership.isOwn(kind: .userShared))
        #expect(!AppleMusicOwnership.isOwn(kind: .editorial))
        #expect(!AppleMusicOwnership.isOwn(kind: .personalMix))
        #expect(!AppleMusicOwnership.isOwn(kind: .replay))
    }
}

@Suite("Playlist without a twin")
struct PlaylistDetailLogicTests {
    @Test("Total length reads like Apple Music's")
    func duration() {
        #expect(PlaylistCopy.duration(ms: (7 * 3600 + 41 * 60) * 1000) == "7 h 41 min")
        #expect(PlaylistCopy.duration(ms: 42 * 60 * 1000) == "42 min")
        #expect(PlaylistCopy.duration(ms: 0) == nil)
    }

    @Test("The header line: platform, kind, count, length")
    func headerLine() {
        let playlist = LibraryPlaylist(platform: .spotify, id: "x", name: "Road Trip Lisbon", trackCount: 112, artworkURL: nil,
                                       detail: "112 tracks · collaborative", isEditable: true, blockedReason: nil, isCollaborative: true)
        #expect(PlaylistCopy.header(playlist, trackCount: 112, durationMs: (7 * 3600 + 41 * 60) * 1000)
                == "Spotify · collaborative · 112 tracks · 7 h 41 min")
    }

    @Test("Availability says how much of the playlist the other side has")
    func availability() {
        var report = AvailabilityReport(total: 112)
        #expect(PlaylistCopy.availability(report, on: .appleMusic) == "Not checked against Apple Music yet.")
        report.checked = 40
        #expect(PlaylistCopy.availability(report, on: .appleMusic) == "Checking 40 of 112 tracks on Apple Music…")
        report.checked = 112
        report.available = Set((0..<108).map(String.init))
        report.missing = ["a", "b", "c", "d"]
        #expect(PlaylistCopy.availability(report, on: .appleMusic)
                == "108 of 112 tracks are available on Apple Music. 4 weren't found there.")
        report.available.remove("0")
        report.close = ["0"]
        #expect(PlaylistCopy.availability(report, on: .appleMusic)
                == "107 of 112 tracks are available on Apple Music. 1 has only a close match, 4 weren't found there.")
    }

    @Test("Who added a track, without naming collaborators")
    func addedBy() {
        #expect(PlaylistCopy.trackDetail(artist: "Ana Moura", addedBy: .collaborator, isMissing: false, other: .appleMusic)
                == "Ana Moura · added by a collaborator")
        #expect(PlaylistCopy.trackDetail(artist: "Mariza", addedBy: .you, isMissing: false, other: .appleMusic)
                == "Mariza · added by you")
        #expect(PlaylistCopy.trackDetail(artist: "Cesária Évora", addedBy: nil, isMissing: true, other: .appleMusic)
                == "Cesária Évora · not on Apple Music")
    }
}

@Suite("Search")
struct LibrarySearchTests {
    private let garden = SeamRef(id: UUID(), name: "Garden Sundays")
    private let drive = SeamRef(id: UUID(), name: "Late Night Drive")
    private let run = SeamRef(id: UUID(), name: "Run Club")

    private func indexed(_ title: String, _ artist: String, album: String? = nil, _ seam: SeamRef,
                         spotify: Bool = true, apple: Bool = true) -> IndexedTrack {
        IndexedTrack(title: title, artist: artist, album: album, artworkURL: nil, seam: seam, onSpotify: spotify, onAppleMusic: apple)
    }

    private var index: [IndexedTrack] {
        [indexed("Running Up That Hill", "Kate Bush", album: "Hounds of Love", drive),
         indexed("Running Up That Hill", "Kate Bush", album: "Hounds of Love", run),
         indexed("Running Up That Hill", "Kate Bush", album: "Hounds of Love", garden, apple: false),
         indexed("Hill Country", "Midlake", garden, apple: false),
         indexed("Hills", "The Weeknd", drive),
         indexed("Nightcall", "Kavinsky", drive)]
    }

    @Test("A track found in several seams is one result, with the playlists per side")
    func groupsBySide() {
        let hits = LibrarySearch.tracks("hill", in: index)
        #expect(hits.map(\.title) == ["Hill Country", "Hills", "Running Up That Hill"])
        let kateBush = hits.last
        #expect(kateBush?.spotify.count == 3)
        #expect(kateBush?.appleMusic.count == 2)
        #expect(LibrarySearch.sideText(kateBush?.spotify ?? [], on: .spotify) == "3 playlists")
        #expect(LibrarySearch.sideText(hits[0].spotify, on: .spotify) == "Garden Sundays")
        #expect(LibrarySearch.sideText(hits[0].appleMusic, on: .appleMusic) == "not on Apple Music")
    }

    @Test("Artists and albums match too, ignoring case and accents")
    func artistAndAlbum() {
        #expect(LibrarySearch.tracks("KATE", in: index).count == 1)
        #expect(LibrarySearch.tracks("hounds", in: index).count == 1)
        #expect(LibrarySearch.tracks("kavínsky", in: index).map(\.title) == ["Nightcall"])
        #expect(LibrarySearch.tracks("  ", in: index).isEmpty)
    }

    @Test("Artists: how many tracks and seams")
    func artists() {
        let hits = LibrarySearch.artists("ka", in: index)
        #expect(hits.map(\.name) == ["Kate Bush", "Kavinsky"])
        #expect(hits.first?.trackCount == 1)
        #expect(hits.first?.seams.count == 3)
    }

    @Test("Recent searches: newest first, no repeats, at most six")
    func recent() {
        var recent = ["Bon Iver", "fado", "Run Club"]
        recent = RecentSearches.adding("FADO", to: recent)
        #expect(recent == ["FADO", "Bon Iver", "Run Club"])
        for query in ["a", "b", "c", "d"] { recent = RecentSearches.adding(query, to: recent) }
        #expect(recent == ["d", "c", "b", "a", "FADO", "Bon Iver"])
        #expect(RecentSearches.adding("  ", to: recent) == recent)
    }
}
