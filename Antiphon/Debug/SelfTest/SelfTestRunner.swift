#if DEBUG
import Foundation
import MusicKit
import SwiftData

/// End-to-end checks against the real Spotify and Apple Music accounts,
/// through the same services the screens use. DEBUG only.
///
/// Open with `-AntiphonScreen selftest` (or `selftest/<scenario>`). Uses its
/// own store, so the person's seams are never touched, and only playlists
/// whose names start with "Antiphon". Every line is logged with
/// `[SELFTEST]` for reading over `devicectl … --console`.
@MainActor
@Observable
final class SelfTestRunner {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let isFailure: Bool
    }

    private(set) var lines: [Line] = []
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var isRunning = false

    let scenario: String?

    init(scenario: String?) {
        self.scenario = scenario
    }

    // MARK: - Names

    /// Antiphon-created on both sides: everything can be written.
    static let ownedName = "Antiphon Self-Test"
    /// Spotify side for the person's own Apple Music playlist.
    static let userSideSpotifyName = "Antiphon Self-Test (own AM)"
    /// Created by the person in the Music app: Antiphon can only append.
    static let userOwnedAppleName = "Antiphon Test"

    // MARK: - Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log("Start \(Date().formatted(date: .omitted, time: .standard)), scenario: \(scenario ?? "all")")
        do {
            if scenario == nil || scenario == "twoway" { try await twoWayOnOwnedPlaylists() }
            // Writes into the person's own playlist, which their real seams
            // may use too: only when asked for by name.
            if scenario == "ownam" { try await oneWayOnPersonsPlaylist() }
            if scenario == "realpreview" { try await previewPersonsSeam() }
        } catch {
            fail("Stopped: \(error)")
        }
        log("DONE passed=\(passed) failed=\(failed)")
    }

    // MARK: - Scenario: two-way, both playlists Antiphon's

    private func twoWayOnOwnedPlaylists() async throws {
        log("== Two-way on Antiphon-created playlists")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.ownedName)
        let appleId = try await applePlaylist(named: Self.ownedName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp, seeds.faint, seeds.midnightCity])
        try await resetApple(appleId)

        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .bidirectional, appleOwned: true)

        // First sync
        var planned = try await env.preview(first: true)
        describe(planned.plan)
        expect(planned.plan.sides[.appleMusic]?.automaticAdds.count == 3, "first sync adds 3 to Apple Music")
        try await env.apply(planned, trigger: .firstSync)
        // Immediately, before Apple Music necessarily lists everything.
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "nothing to do right after the first sync")
        if !planned.plan.isEmpty { describe(planned.plan) }
        var apple = try await waitForApple(env, titles: ["Word Up", "Faint", "Midnight City"])
        expect(apple.count == 3, "Apple Music has 3 tracks after the first sync (has \(apple.count))")
        checkAlbum(apple, title: "Word Up", album: seeds.wordUp.album)
        checkAlbum(apple, title: "Faint", album: seeds.faint.album)
        try await env.dumpRows("before the second sync")
        planned = try await env.preview()
        try await env.apply(planned, trigger: .manual)
        try await env.dumpRows("after the second sync (ids anchored)")

        // Removed on Apple Music → question
        try await removeOnApple(env, title: "Word Up")
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.conflicts.count == 1 && planned.plan.conflicts.first?.removedFrom == .appleMusic,
               "removing Word Up on Apple Music becomes one question")
        try await env.apply(planned, trigger: .manual)
        var conflicts = try await env.conflicts()
        expect(conflicts.count == 1, "the question is waiting for an answer (\(conflicts.count))")

        // Put it back
        if let item = conflicts.first {
            let outcome = try await env.resolve(item, as: .restore)
            log("restore landed: \(outcome.landed.map { "\($0.track.title) [\($0.track.id)] \($0.track.album ?? "-")" })")
        }
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "nothing to ask right after putting it back")
        if !planned.plan.isEmpty { describe(planned.plan) }
        apple = try await waitForApple(env, titles: ["Word Up"])
        checkAlbum(apple, title: "Word Up", album: seeds.wordUp.album)
        conflicts = try await env.conflicts()
        expect(conflicts.isEmpty, "no question left after putting it back (\(conflicts.count))")
        try await env.dumpRows("after restore")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync after putting it back")
        if !planned.plan.isEmpty { describe(planned.plan) }

        // Removed again → noticed again
        try await removeOnApple(env, title: "Word Up")
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.conflicts.count == 1, "removing Word Up again is noticed again")
        try await env.apply(planned, trigger: .manual)

        // Another sync while the question is open must not answer it.
        planned = try await env.preview()
        expect(planned.plan.conflicts.count == 1, "the question survives another preview (\(planned.plan.conflicts.count))")
        try await env.apply(planned, trigger: .manual)
        conflicts = try await env.conflicts()
        expect(conflicts.count == 1, "the question survives another sync (\(conflicts.count))")
        try await env.dumpRows("after a second sync with an open question")

        // Keep the difference, across two more syncs
        if let item = conflicts.first { _ = try await env.resolve(item, as: .keepDifference) }
        for round in 1...2 {
            planned = try await env.preview()
            expect(planned.plan.isEmpty, "keeping the difference holds (sync \(round))")
            if !planned.plan.isEmpty { describe(planned.plan) }
            try await env.apply(planned, trigger: .manual)
        }
        conflicts = try await env.conflicts()
        expect(conflicts.isEmpty, "no question after keeping the difference (\(conflicts.count))")

        // Removed on Apple Music, then added back by hand in the Music app
        try await removeOnApple(env, title: "Midnight City")
        planned = try await env.preview()
        try await env.apply(planned, trigger: .manual)
        expect(try await env.conflicts().count == 1, "removing Midnight City on Apple Music asks")
        let midnight = try await appleCatalogTrack("M83 Midnight City", album: "Hurry Up")
        _ = try await env.editor.add([midnight], to: appleId, on: .appleMusic)
        _ = try await waitForApple(env, titles: ["Midnight City"])
        planned = try await env.preview()
        expect(planned.plan.conflicts.isEmpty, "adding it back in the Music app answers the question")
        try await env.apply(planned, trigger: .manual)
        expect(try await env.conflicts().isEmpty, "no question left once it's back")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync with Midnight City back")
        if !planned.plan.isEmpty { describe(planned.plan) }

        // A row an earlier version stranded: one-sided, no question, gone from Apple Music
        try await removeOnApple(env, title: "Faint")
        try env.strand(title: "Faint")
        planned = try await env.preview()
        expect(planned.plan.conflicts.first?.track.title == "Faint", "a stranded row is asked about again")
        try await env.apply(planned, trigger: .manual)
        conflicts = try await env.conflicts()
        if let item = conflicts.first(where: { $0.conflict.track.title == "Faint" }) {
            _ = try await env.resolve(item, as: .restore)
        }
        apple = try await waitForApple(env, titles: ["Faint"])
        checkAlbum(apple, title: "Faint", album: seeds.faint.album)
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync after putting Faint back")
        if !planned.plan.isEmpty { describe(planned.plan) }

        // Added on Spotify → added on Apple Music
        _ = try await env.editor.add([seeds.holocene], to: spotifyId, on: .spotify)
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.sides[.appleMusic]?.automaticAdds.count == 1, "a track added on Spotify is added on Apple Music")
        try await env.apply(planned, trigger: .manual)
        apple = try await waitForApple(env, titles: ["Holocene"])
        checkAlbum(apple, title: "Holocene", album: seeds.holocene.album)

        // Removed on Spotify → remove on Apple Music too
        try await env.editor.remove([seeds.holocene], from: spotifyId, on: .spotify)
        planned = try await env.preview()
        expect(planned.plan.conflicts.first?.removedFrom == .spotify, "removing Holocene on Spotify becomes a question")
        try await env.apply(planned, trigger: .manual)
        conflicts = try await env.conflicts()
        if let item = conflicts.first { _ = try await env.resolve(item, as: .removeOnOtherSide) }
        apple = try await env.appleTracks()
        expect(!apple.contains { $0.title.localizedCaseInsensitiveContains("Holocene") }, "Holocene is gone from Apple Music too")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync after removing on both sides")
        if !planned.plan.isEmpty { describe(planned.plan) }

        // Added on Apple Music → added on Spotify
        let pumpIt = try await appleCatalogTrack("Pump It Black Eyed Peas", album: "Monkey Business")
        _ = try await env.editor.add([pumpIt], to: appleId, on: .appleMusic)
        _ = try await waitForApple(env, titles: ["Pump It"])
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.sides[.spotify]?.automaticAdds.count == 1, "a track added on Apple Music is added on Spotify")
        try await env.apply(planned, trigger: .manual)
        let spotify = try await env.editor.tracks(in: spotifyId, on: .spotify)
        checkAlbum(spotify, title: "Pump It", album: "Monkey Business")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync at the end")
        if !planned.plan.isEmpty { describe(planned.plan) }
    }

    // MARK: - Scenario: one way into the person's own Apple Music playlist

    private func oneWayOnPersonsPlaylist() async throws {
        log("== One way into the person's own playlist (\(Self.userOwnedAppleName))")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.userSideSpotifyName)
        let appleId = try await applePlaylist(named: Self.userOwnedAppleName, createIfMissing: false)
        try await resetSpotify(spotifyId, to: [seeds.wordUp, seeds.faint])

        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .spotifyToApple, appleOwned: false)
        var planned = try await env.preview(first: true)
        describe(planned.plan)
        try await env.apply(planned, trigger: .firstSync)
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "nothing to do right after the first sync (own playlist)")
        if !planned.plan.isEmpty { describe(planned.plan) }
        let apple = try await waitForApple(env, titles: ["Word Up", "Faint"])
        checkAlbum(apple, title: "Word Up", album: seeds.wordUp.album)
        checkAlbum(apple, title: "Faint", album: seeds.faint.album)
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "nothing to do once Apple Music lists them")
        if !planned.plan.isEmpty { describe(planned.plan) }
    }

    // MARK: - Read-only: preview the person's own "Antiphon Test" seam

    /// A dry run on the real store. Previews write nothing.
    private func previewPersonsSeam() async throws {
        log("== Preview of the person's seam \(Self.userOwnedAppleName) (read only)")
        let container = SharedModelContainer.container
        let pairs = try ModelContext(container).fetch(FetchDescriptor<SyncPair>())
        guard let pair = pairs.first(where: { $0.spotifyPlaylistName == Self.userOwnedAppleName }) else {
            throw SelfTestError("no seam named \(Self.userOwnedAppleName)")
        }
        let planned = try await LiveSyncService(modelContainer: container).preview(seamId: pair.id, isFirstSync: false, progress: nil)
        describe(planned.plan)
        expect(planned.plan.conflicts.contains { $0.track.title.localizedCaseInsensitiveContains("Word Up") },
               "the stuck Word Up removal is asked about again")
    }

    // MARK: - Environment

    /// A seam in a throwaway store, with the live services.
    private struct Env {
        let container: ModelContainer
        let pairId: UUID
        let spotifyId: String
        let appleId: String
        let sync: LiveSyncService
        let repository: SwiftDataSeamRepository
        let editor = LivePlaylistEditor(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())

        @MainActor
        init(spotifyId: String, appleId: String, direction: SyncDirection, appleOwned: Bool) throws {
            let url = URL.applicationSupportDirectory.appending(path: "selftest-\(UUID().uuidString).store")
            container = try SharedModelContainer.make(url: url)
            let context = ModelContext(container)
            let pair = SyncPair(spotifyPlaylistId: spotifyId, spotifyPlaylistName: "self-test",
                                appleMusicPlaylistId: appleId, appleMusicPlaylistName: "self-test", syncDirection: direction)
            pair.spotifyCreatedByAntiphon = true
            pair.appleMusicCreatedByAntiphon = appleOwned
            context.insert(pair)
            try context.save()
            pairId = pair.id
            self.spotifyId = spotifyId
            self.appleId = appleId
            sync = LiveSyncService(modelContainer: container)
            repository = SwiftDataSeamRepository(modelContainer: container)
        }

        func preview(first: Bool = false) async throws -> PlannedSync {
            try await sync.preview(seamId: pairId, isFirstSync: first, progress: nil)
        }

        func apply(_ planned: PlannedSync, trigger: SyncTrigger) async throws {
            let plan = planned.plan
            let keys = Set(plan.sides.values.flatMap { ($0.automaticAdds + $0.reviewAdds).map { TrackKey($0.source) } })
            let result = await sync.apply(planned, approving: keys, trigger: trigger, progress: nil)
            guard result.status != .failed, !result.isStale else {
                throw SelfTestError("apply failed: \(result.message ?? "-") stale=\(result.isStale)")
            }
        }

        func conflicts() async throws -> [ConflictItem] {
            try await repository.conflicts(seamId: pairId)
        }

        func resolve(_ item: ConflictItem, as outcome: ConflictOutcome) async throws -> OperationRunner.Outcome {
            let resolution = ConflictResolver.resolve(item.conflict, as: outcome, appleMusicCanRemove: item.appleMusicCanRemove)
            return try await sync.resolve([resolution], seamId: pairId)
        }

        /// Puts a row in the state an earlier version left behind: one-sided,
        /// no question, as if never removed.
        @MainActor
        func strand(title: String) throws {
            let context = ModelContext(container)
            guard let row = try context.fetch(FetchDescriptor<CachedTrack>())
                .first(where: { $0.syncPair?.id == pairId && $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw SelfTestError("no row for \(title)")
            }
            row.source = .spotify
            row.removalFlag = nil
            row.removalFlaggedAt = nil
            row.removalKeptAt = nil
            try context.save()
        }

        func appleTracks() async throws -> [CatalogTrack] {
            try await editor.tracks(in: appleId, on: .appleMusic)
        }

        /// What Antiphon remembers per track, next to what the playlists hold.
        @MainActor
        func dumpRows(_ label: String) async throws {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<CachedTrack>()).filter { $0.syncPair?.id == pairId }
            let apple = try await appleTracks()
            SelfTestRunner.print("rows \(label): \(rows.count); Apple Music ids: \(apple.map { "\($0.title)=\($0.id)" })")
            for row in rows.sorted(by: { $0.title < $1.title }) {
                SelfTestRunner.print("  \(row.title): sp=\(row.spotifyTrackUri ?? "-") am=\(row.appleMusicTrackId ?? "-") source=\(row.source) state=\(row.syncState.map { "\($0)" } ?? "-") flag=\(String(describing: row.removalFlag)) kept=\(row.removalKeptAt != nil)")
            }
        }
    }

    // MARK: - Playlists

    private struct Seeds {
        let wordUp, faint, midnightCity, holocene: CatalogTrack
    }

    private var cachedSeeds: Seeds?

    private func spotifySeeds() async throws -> Seeds {
        if let cachedSeeds { return cachedSeeds }
        let seeds = Seeds(
            wordUp: try await spotifyTrack("track:Word Up artist:Korn", album: "Greatest Hits"),
            faint: try await spotifyTrack("track:Faint artist:Linkin Park", album: "Meteora"),
            midnightCity: try await spotifyTrack("track:Midnight City artist:M83", album: "Hurry Up"),
            holocene: try await spotifyTrack("track:Holocene artist:Bon Iver", album: "Bon Iver")
        )
        for track in [seeds.wordUp, seeds.faint, seeds.midnightCity, seeds.holocene] {
            log("seed: \(track.title) — \(track.album ?? "-") [\(track.isrc ?? "no isrc")]")
        }
        cachedSeeds = seeds
        return seeds
    }

    private func spotifyTrack(_ query: String, album: String) async throws -> CatalogTrack {
        let results = try await SpotifyAPIClient().search(query: query, limit: 10)
        guard let track = results.first(where: { $0.album?.name.localizedCaseInsensitiveContains(album) == true }) ?? results.first else {
            throw SelfTestError("no Spotify result for \(query)")
        }
        return CatalogTrack(track)
    }

    private func appleCatalogTrack(_ query: String, album: String) async throws -> CatalogTrack {
        let songs = try await AppleMusicManager().searchCatalog(query: query, limit: 10)
        guard let song = songs.first(where: { $0.albumTitle?.localizedCaseInsensitiveContains(album) == true }) ?? songs.first else {
            throw SelfTestError("no Apple Music result for \(query)")
        }
        return CatalogTrack(song)
    }

    private func spotifyPlaylist(named name: String) async throws -> String {
        precondition(name.hasPrefix("Antiphon"))
        let client = SpotifyAPIClient()
        if let existing = try await client.getAllPlaylists().first(where: { $0.name == name }) { return existing.id }
        log("creating Spotify playlist \(name)")
        return try await client.createPlaylist(name: name, description: "Antiphon self-test. Safe to delete.").id
    }

    private func applePlaylist(named name: String, createIfMissing: Bool) async throws -> String {
        precondition(name.hasPrefix("Antiphon"))
        let manager = AppleMusicManager()
        if let existing = try await manager.fetchUserPlaylists().first(where: { $0.name == name }) { return existing.id.rawValue }
        guard createIfMissing else { throw SelfTestError("Apple Music playlist \(name) not found") }
        log("creating Apple Music playlist \(name)")
        return try await manager.createPlaylist(name: name, description: "Antiphon self-test. Safe to delete.").id.rawValue
    }

    private func resetSpotify(_ id: String, to tracks: [CatalogTrack]) async throws {
        let editor = LivePlaylistEditor(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        let current = try await editor.tracks(in: id, on: .spotify)
        if !current.isEmpty { try await editor.remove(current, from: id, on: .spotify) }
        _ = try await editor.add(tracks, to: id, on: .spotify)
    }

    private func resetApple(_ id: String) async throws {
        let editor = LivePlaylistEditor(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        let current = try await editor.tracks(in: id, on: .appleMusic)
        if !current.isEmpty { try await editor.remove(current, from: id, on: .appleMusic) }
        let left = try await editor.tracks(in: id, on: .appleMusic)
        expect(left.isEmpty, "Apple Music self-test playlist emptied (\(left.count) left)")
    }

    /// Apple Music lists added tracks with a delay: wait (up to 3 minutes)
    /// and log how long it took.
    private func waitForApple(_ env: Env, titles: [String]) async throws -> [CatalogTrack] {
        let start = Date()
        while true {
            let tracks = try await env.appleTracks()
            let missing = titles.filter { title in !tracks.contains { $0.title.localizedCaseInsensitiveContains(title) } }
            let waited = Int(Date().timeIntervalSince(start))
            if missing.isEmpty {
                if waited > 0 { log("Apple Music listed \(titles) after \(waited) s") }
                return tracks
            }
            if waited > 180 {
                expect(false, "Apple Music lists \(missing) within 3 minutes")
                return tracks
            }
            try await Task.sleep(for: .seconds(3))
        }
    }

    private func removeOnApple(_ env: Env, title: String) async throws {
        let apple = try await env.appleTracks()
        guard let track = apple.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
            throw SelfTestError("\(title) isn't on Apple Music to remove")
        }
        try await env.editor.remove([track], from: env.appleId, on: .appleMusic)
        log("removed \(track.title) [\(track.id)] on Apple Music")
    }

    // MARK: - Checks

    private func checkAlbum(_ tracks: [CatalogTrack], title: String, album: String?) {
        let found = tracks.filter { $0.title.localizedCaseInsensitiveContains(title) }
        guard let track = found.first else { return expect(false, "\(title) is in the playlist") }
        expect(found.count == 1, "\(title) is in the playlist once (\(found.count))")
        let base = album.map(ReleasePreference.baseAlbum) ?? ""
        expect(track.album.map { ReleasePreference.baseAlbum($0).localizedCaseInsensitiveContains(base) } ?? false,
               "\(title) is from \(album ?? "-") (got \(track.album ?? "-"), id \(track.id))")
    }

    private func describe(_ plan: SyncPlan) {
        for (platform, side) in plan.sides.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            log("  plan → \(platform.rawValue): add \(side.automaticAdds.map(\.source.title)) review \(side.reviewAdds.map(\.source.title)) remove \(side.removals.map(\.track.title)) present \(side.alreadyPresent.count) unavailable \(side.unavailable.map(\.source.title))")
        }
        if !plan.conflicts.isEmpty { log("  plan conflicts: \(plan.conflicts.map { "\($0.track.title) removed on \($0.removedFrom.rawValue)" })") }
        log("  plan inSync \(plan.inSyncCount) unchecked \(plan.uncheckedCount) empty \(plan.isEmpty)")
    }

    private func expect(_ condition: Bool, _ message: String) {
        if condition { passed += 1; log("PASS \(message)") } else { failed += 1; fail("FAIL \(message)") }
    }

    private func log(_ text: String) {
        lines.append(Line(text: text, isFailure: false))
        Self.print(text)
    }

    private func fail(_ text: String) {
        lines.append(Line(text: text, isFailure: true))
        Self.print(text)
    }

    nonisolated static func print(_ text: String) {
        Swift.print("[SELFTEST] \(text)")
    }
}

struct SelfTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
