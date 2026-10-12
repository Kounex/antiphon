import Foundation
import Testing
@testable import Antiphon

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seam(_ name: String, synced: Int = 10, review: Int = 0, result: SyncResultStatus? = .success,
                      paused: Bool = false, checked: TimeInterval? = -600) -> SeamSummary {
        SeamSummary(
            id: UUID(),
            spotify: SeamSide(platform: .spotify, playlistId: "s", name: name, artworkURL: URL(string: "https://img/\(name)")),
            appleMusic: SeamSide(platform: .appleMusic, playlistId: "a", name: name, artworkURL: nil),
            direction: .spotifyToApple, isMonitored: true, isPaused: paused, monitorIntervalMinutes: 15,
            lastCheckedAt: checked.map { now.addingTimeInterval($0) }, lastResult: result,
            counts: SeamCounts(synced: synced, review: review, missing: 0, total: synced + review)
        )
    }

    @Test("Seams that need you come first, then the rest by when they were checked")
    func order() {
        let calm = seam("Garden Sundays", checked: -60)
        let older = seam("Run Club", checked: -3600)
        let review = seam("Late Night Drive", review: 3, checked: -7200)
        let broken = seam("Vinyl Rips", result: .failed)
        let snapshot = WidgetSnapshot.build(seams: [calm, older, review, broken], newTracks: [], now: now)
        #expect(snapshot.seams.map(\.name) == ["Late Night Drive", "Vinyl Rips", "Garden Sundays", "Run Club"])
        #expect(snapshot.seams.map(\.status) == [.review(3), .failed, .inSync, .inSync])
        #expect(snapshot.seams.first?.artworkURL == URL(string: "https://img/Late Night Drive"))
    }

    @Test("Totals, and when anything was last checked")
    func totals() {
        let snapshot = WidgetSnapshot.build(seams: [seam("A", synced: 1_000, checked: -120), seam("B", synced: 284, checked: nil),
                                                    seam("C", synced: 5, paused: true)], newTracks: [], now: now)
        #expect(snapshot.tracksInSync == 1_289)
        #expect(snapshot.seamCount == 3)
        #expect(snapshot.lastCheckedAt == now.addingTimeInterval(-120))
        #expect(snapshot.seams.last?.status == .paused)
    }

    @Test("New this week: what New tracks lists from the last 7 days, across how many playlists")
    func newThisWeek() {
        let a = seam("A"), b = seam("B")
        func track(_ seam: SeamSummary, daysAgo: Double) -> NewTrack {
            NewTrack(id: UUID(), seamId: seam.id, seamName: seam.name, direction: seam.direction, title: "T", artist: "A",
                     artworkURL: nil, landedOn: .appleMusic, date: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let tracks = Array(repeating: track(a, daysAgo: 1), count: 10) + Array(repeating: track(b, daysAgo: 6.9), count: 4)
            + [track(b, daysAgo: 8)]
        let snapshot = WidgetSnapshot.build(seams: [a, b], newTracks: tracks, now: now)
        #expect(snapshot.newThisWeek == .init(tracks: 14, playlists: 2))
    }

    @Test("The same seams later are the same content, so the widgets aren't reloaded for nothing")
    func sameContent() {
        let seams = [seam("A"), seam("B", review: 2)]
        let first = WidgetSnapshot.build(seams: seams, newTracks: [], now: now)
        let later = WidgetSnapshot.build(seams: seams, newTracks: [], now: now.addingTimeInterval(60))
        #expect(first != later)
        #expect(first.hasSameContent(as: later))
        let changed = WidgetSnapshot.build(seams: [seams[0]], newTracks: [], now: now)
        #expect(!first.hasSameContent(as: changed))
    }

    @Test("Written to the App Group as JSON and read back the same")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = WidgetSnapshot.build(seams: [seam("A", review: 2)], newTracks: [], now: now)
        try snapshot.write(to: folder)
        #expect(WidgetSnapshot.read(from: folder) == snapshot)
        #expect(WidgetSnapshot.read(from: folder.appending(path: "missing")) == nil)
    }
}
