import Foundation
import Testing
@testable import Antiphon

@Suite("Widget copy")
struct WidgetCopyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let english = Locale(identifier: "en_US")

    @Test("When the seams were last checked")
    func checked() {
        #expect(WidgetCopy.checked(now.addingTimeInterval(-120), now: now) == "checked 2 min ago")
        #expect(WidgetCopy.checked(now.addingTimeInterval(-10), now: now) == "checked just now")
        #expect(WidgetCopy.checked(nil, now: now) == "not checked yet")
    }

    @Test("The In sync tile: the number, then what it counts")
    func inSync() {
        #expect(WidgetCopy.number(1_284, locale: english) == "1,284")
        #expect(WidgetCopy.number(1_284, locale: Locale(identifier: "de_DE")) == "1.284")
        #expect(WidgetCopy.tracksAndSeams(seams: 9) == "tracks · 9 seams")
        #expect(WidgetCopy.tracksAndSeams(seams: 1) == "tracks · 1 seam")
    }

    @Test("New this week, and a quiet week said plainly")
    func newThisWeek() {
        #expect(WidgetCopy.newThisWeek(.init(tracks: 14, playlists: 3)) == "14 tracks across 3 playlists")
        #expect(WidgetCopy.newThisWeek(.init(tracks: 1, playlists: 1)) == "1 track in 1 playlist")
        #expect(WidgetCopy.newThisWeek(.init(tracks: 0, playlists: 0)) == "Nothing new this week")
    }

    @Test("Before the app has written anything, the widgets say what to do")
    func empty() {
        #expect(WidgetCopy.noSeams == "No seams yet. Open Antiphon to stitch two playlists.")
        #expect(WidgetCopy.notLoaded == "Open Antiphon once to show your seams here.")
    }

    @Test("Widget links open the seam, or New tracks")
    func links() throws {
        let id = UUID()
        #expect(WidgetLink.seam(id).url == URL(string: "antiphon://seam/\(id.uuidString)"))
        #expect(WidgetLink(url: WidgetLink.seam(id).url) == .seam(id))
        #expect(WidgetLink(url: WidgetLink.newTracks.url) == .newTracks)
        #expect(WidgetLink(url: try #require(URL(string: "antiphon://spotify-callback?code=x"))) == nil)
    }
}
