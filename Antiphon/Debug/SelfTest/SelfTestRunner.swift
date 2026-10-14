#if DEBUG
import ActivityKit
import BackgroundTasks
import Foundation
import MusicKit
import SwiftData
import UIKit
import UserNotifications

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
    /// One way with "Same order", Antiphon-created on both sides.
    static let sameOrderName = "Antiphon Self-Test (same order)"
    /// Two way, Antiphon-created on both sides, for undo.
    static let undoName = "Antiphon Self-Test (undo)"

    // MARK: - Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log("Start \(Date().formatted(date: .omitted, time: .standard)), scenario: \(scenario ?? "all")")
        do {
            if scenario == nil || scenario == "twoway" { try await twoWayOnOwnedPlaylists() }
            if scenario == nil || scenario == "sameorder" { try await sameOrderOneWay() }
            if scenario == nil || scenario == "album" { try await originalAlbum() }
            if scenario == nil || scenario == "library" { try await libraryReadOnly() }
            if scenario == nil || scenario == "undo" { try await undoTwoWay() }
            if scenario == nil || scenario == "recheck" { try await recheckUnavailable() }
            if scenario == nil || scenario == "monitor" { try await monitorRun() }
            if scenario == nil || scenario == "opencheck" { try await openCheck() }
            // Writes into the person's own playlist, which their real seams
            // may use too: only when asked for by name.
            if scenario == "ownam" { try await oneWayOnPersonsPlaylist() }
            if scenario == "realpreview" { try await previewPersonsSeam() }
            if scenario == "matchprobe" { try await matchProbe() }
            // Changes the Home Screen icon (iOS shows a notice): only by name.
            if scenario == "icon" { try await iconFollowsTheme() }
            // Needs the person to tap a notification button: only by name.
            if scenario == "ask" { try await askOnLockScreen() }
            // Shows a Live Activity for the person to look at: only by name.
            if scenario == "live" { try await liveActivity() }
        } catch {
            fail("Stopped: \(error)")
        }
        // Scenarios write their throwaway stores into the App Group: put the
        // dev app's own snapshot back for its widgets.
        await WidgetSnapshotWriter.refresh(modelContainer: SharedModelContainer.container)
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
        try await checkOrder(env, "after the first sync")
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
        try await checkOrder(env, "after putting Word Up back")
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
        try await moveToSecond(env, title: "Holocene", on: .spotify)
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.sides[.appleMusic]?.automaticAdds.count == 1, "a track added on Spotify is added on Apple Music")
        try await env.apply(planned, trigger: .manual)
        apple = try await waitForApple(env, titles: ["Holocene"])
        checkAlbum(apple, title: "Holocene", album: seeds.holocene.album)
        try await checkOrder(env, "after adding Holocene second on Spotify")

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
        try await moveToSecond(env, title: "Pump It", on: .appleMusic)
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.sides[.spotify]?.automaticAdds.count == 1, "a track added on Apple Music is added on Spotify")
        try await env.apply(planned, trigger: .manual)
        let spotify = try await env.editor.tracks(in: spotifyId, on: .spotify)
        checkAlbum(spotify, title: "Pump It", album: "Monkey Business")
        try await checkOrder(env, "after adding Pump It second on Apple Music")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync at the end")
        if !planned.plan.isEmpty { describe(planned.plan) }
    }

    // MARK: - Scenario: one way, "Same order"

    private func sameOrderOneWay() async throws {
        log("== One way with Same order, both playlists Antiphon's")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.sameOrderName)
        let appleId = try await applePlaylist(named: Self.sameOrderName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp, seeds.faint, seeds.midnightCity])
        try await resetApple(appleId)

        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .spotifyToApple, appleOwned: true, placement: .mirror)
        var planned = try await env.preview(first: true)
        describe(planned.plan)
        try await env.apply(planned, trigger: .firstSync)
        _ = try await waitForApple(env, titles: ["Word Up", "Faint", "Midnight City"])
        try await checkOrder(env, "after the first sync")
        planned = try await env.preview()
        try await env.apply(planned, trigger: .manual)

        // A track only on Apple Music keeps its slot.
        let holocene = try await appleCatalogTrack("Holocene Bon Iver", album: "Bon Iver")
        _ = try await env.editor.add([holocene], to: appleId, on: .appleMusic)
        _ = try await waitForApple(env, titles: ["Holocene"])

        // Reordered on Spotify → Apple Music follows.
        try await move(env, title: "Midnight City", to: 0, on: .spotify)
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.reorders == .appleMusic, "the preview says Apple Music is put in Spotify's order")
        expect(planned.plan.automaticAddCount == 0 && planned.plan.removalCount == 0 && planned.plan.conflicts.isEmpty,
               "reordering adds, removes and asks nothing")
        log("headline: \(PlanCopy.headline(for: planned.plan))")
        try await env.apply(planned, trigger: .manual)
        try await checkOrder(env, "after reordering Spotify")
        var apple = try await env.appleTracks().map(\.title)
        expect(apple.last?.localizedCaseInsensitiveContains("Holocene") == true, "the Apple Music-only track keeps its place (\(apple))")

        // Reordered by hand on Apple Music → put back in Spotify's order.
        try await move(env, title: "Faint", to: 0, on: .appleMusic)
        planned = try await env.preview()
        expect(planned.plan.reorders == .appleMusic, "a hand-made Apple Music order is noticed")
        try await env.apply(planned, trigger: .manual)
        try await checkOrder(env, "after reordering Apple Music by hand")
        apple = try await env.appleTracks().map(\.title)
        expect(apple.last?.localizedCaseInsensitiveContains("Holocene") == true, "Holocene still in its place (\(apple))")

        // Undo puts the hand-made order back: the run logged what it moved.
        guard let reorderRun = try await env.repository.runs().first else { throw SelfTestError("no reorder run in History") }
        log("history: \(ActivityCopy.line(reorderRun))")
        expect(reorderRun.changes.contains { $0.kind == .move }, "the run recorded its moves")
        let undoPlan = try await env.sync.undoPreview(runId: reorderRun.id)
        log("undo says: \(undoPlan.summary)")
        _ = try await env.sync.undo(runId: reorderRun.id)
        apple = try await env.appleTracks().map(\.title)
        expect(apple.first?.localizedCaseInsensitiveContains("Faint") == true
               && apple.last?.localizedCaseInsensitiveContains("Holocene") == true,
               "undo restores the order before the run: Faint first again, Holocene last (\(apple))")
        planned = try await env.preview()
        try await env.apply(planned, trigger: .manual)
        try await checkOrder(env, "after syncing again")

        // Holocene now also on Spotify, second: matched, then put in order.
        _ = try await env.editor.add([seeds.holocene], to: spotifyId, on: .spotify)
        try await move(env, title: "Holocene", to: 1, on: .spotify)
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.reorders == .appleMusic, "the preview sees Holocene's new place")
        try await env.apply(planned, trigger: .manual)
        try await checkOrder(env, "after adding Holocene second on Spotify")

        // A track new to both, added third on Spotify, lands third.
        let pumpIt = try await spotifyTrack("track:Pump It artist:Black Eyed Peas", album: "Monkey Business")
        _ = try await env.editor.add([pumpIt], to: spotifyId, on: .spotify)
        try await move(env, title: "Pump It", to: 2, on: .spotify)
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.automaticAddCount == 1, "Pump It is added")
        try await env.apply(planned, trigger: .manual)
        apple = try await waitForApple(env, titles: ["Pump It"]).map(\.title)
        try await checkOrder(env, "after adding Pump It third on Spotify")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "in sync at the end (Same order)")
        if !planned.plan.isEmpty { describe(planned.plan) }
    }

    // MARK: - Read only: which album "Original album" picks

    private func originalAlbum() async throws {
        log("== Original album (read only)")
        let catalog = AppleMusicTrackCatalog(manager: AppleMusicManager())
        let cases: [(query: String, album: String, original: String)] = [
            ("track:Waiting for the End artist:Linkin Park", "Papercuts", "A Thousand Suns"),
            ("track:Word Up artist:Korn", "Greatest Hits", "Greatest Hits"),
            // Spotify's "Word Up! (The Remixes)" is Apple's "Word Up!: The Remixes - EP" (2026-10-14).
            ("track:Word Up artist:Korn", "The Remixes", "Greatest Hits")
        ]
        for item in cases {
            let source = try await spotifyTrack(item.query, album: item.album)
            log("source: \(source.title) — \(source.album ?? "-") [\(source.isrc ?? "-")]")
            for choice in ReleaseChoice.allCases {
                let outcome = try await MatchFinder.find(source, in: catalog, targetPlaylist: [], preferences: VersionPreferences(release: choice))
                let picks = ([outcome.best].compactMap { $0 } + outcome.alternatives)
                    .map { "\($0.track.album ?? "?") (\($0.track.releaseYear.map(String.init) ?? "?")) \($0.confidence)%" }
                log("  \(choice): \(picks.joined(separator: " | "))")
                let album = outcome.best?.track.album ?? "-"
                expect((outcome.best?.confidence ?? 0) >= MatchFinder.strongMatch, "\(source.title), \(choice): a solid match (\(album))")
                let expected = choice == .original ? item.original : ReleasePreference.baseAlbum(source.album ?? "")
                expect(ReleasePreference.baseAlbum(album).localizedCaseInsensitiveContains(ReleasePreference.baseAlbum(expected)),
                       "\(source.title), \(choice): from \(expected) (got \(album))")
            }
        }
    }

    // MARK: - Scenario: match probe (read only, by name)

    /// Every candidate the matcher sees for one song, both ways, under each
    /// album setting. `-AntiphonProbe "Title|Artist"` picks the song.
    private func matchProbe() async throws {
        let spec = (UserDefaults.standard.string(forKey: "AntiphonProbe") ?? "Word Up|Korn").split(separator: "|").map(String.init)
        let title = spec[0], artist = spec.count > 1 ? spec[1] : ""
        log("== Match probe (read only): \(title) by \(artist)")
        let spotify = SpotifyTrackCatalog(client: SpotifyAPIClient())
        let apple = AppleMusicTrackCatalog(manager: AppleMusicManager())
        func describe(_ t: CatalogTrack) -> String {
            let length = t.durationMs.map { String(format: "%d:%02d", $0 / 60_000, $0 / 1000 % 60) } ?? "?"
            return "\(t.title) — \(t.album ?? "?") (\(t.releaseYear.map(String.init) ?? "?"), \(t.albumKind.map { "\($0)" } ?? "kind ?")) \(length) isrc \(t.isrc ?? "-")"
        }
        let ways: [(String, any TrackCatalog, any TrackCatalog)] = [("Spotify → Apple Music", spotify, apple), ("Apple Music → Spotify", apple, spotify)]
        for (way, from, into) in ways {
            log("-- \(way)")
            let sources = try await from.search("\(artist) \(title)", limit: 10)
                .filter { $0.title.localizedCaseInsensitiveContains(title) }
            for source in sources { log("source option: \(describe(source))") }
            for source in sources where !(source.album ?? "").localizedCaseInsensitiveContains("greatest") {
                log("SOURCE \(describe(source))")
                if let isrc = source.isrc {
                    for hit in try await into.tracks(withISRC: isrc) { log("  isrc hit: \(describe(hit))") }
                }
                for choice in ReleaseChoice.allCases {
                    let outcome = try await MatchFinder.find(source, in: into, targetPlaylist: [], preferences: VersionPreferences(release: choice))
                    log("  \(choice):")
                    for c in [outcome.best].compactMap({ $0 }) + outcome.alternatives {
                        log("    \(c.confidence)% \(c.reason) | \(describe(c.track))")
                    }
                }
            }
        }
    }

    // MARK: - Scenario: the Home Screen icon follows the theme

    private func iconFollowsTheme() async throws {
        log("== Home Screen icon follows Appearance")
        expect(UIApplication.shared.supportsAlternateIcons, "the app supports alternate icons")
        for appearance in [AppAppearance.dark, .light, .system] {
            await AppIconSwitcher.apply(appearance)
            try await Task.sleep(for: .seconds(2))
            let current = UIApplication.shared.alternateIconName
            expect(current == appearance.alternateIconName, "\(appearance.title): icon is \(current ?? "the adaptive one")")
        }
        // Two quick choices: the later one wins.
        AppIconSwitcher.request(.light)
        AppIconSwitcher.request(.dark)
        try await Task.sleep(for: .seconds(4))
        expect(UIApplication.shared.alternateIconName == "AppIcon-Dark", "Light then Dark at once: icon is Dark")
        await AppIconSwitcher.apply(.system)
    }

    // MARK: - Scenario: unavailable tracks are looked up again

    private func recheckUnavailable() async throws {
        log("== Recheck a track that wasn't found, one way into Antiphon's Apple Music playlist")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.sameOrderName)
        let appleId = try await applePlaylist(named: Self.sameOrderName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp, seeds.faint])
        try await resetApple(appleId)
        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .spotifyToApple, appleOwned: true)
        try await env.apply(try await env.preview(first: true), trigger: .firstSync)
        _ = try await waitForApple(env, titles: ["Word Up", "Faint"])
        try await env.apply(try await env.preview(), trigger: .manual)

        // Faint as if it hadn't been found three times, last tried 8 days ago.
        try await removeOnApple(env, title: "Faint")
        try env.markUnavailable(title: "Faint", lastTried: Date().addingTimeInterval(-8 * 86_400))
        let preferences = AppPreferences.shared
        let saved = preferences.recheckCadence
        defer { preferences.recheckCadence = saved }

        preferences.recheckCadence = .never
        var planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.automaticAddCount == 0, "with “Never”, a track that wasn't found stays unchecked")

        preferences.recheckCadence = .weekly
        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.side(.appleMusic).automaticAdds.map(\.source.title).contains { $0.localizedCaseInsensitiveContains("Faint") },
               "weekly: after 8 days it's looked up again and planned")
        try await env.apply(planned, trigger: .manual)
        let apple = try await waitForApple(env, titles: ["Faint"])
        expect(apple.contains { $0.title.localizedCaseInsensitiveContains("Faint") }, "the sync adds it to Apple Music")
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "settled afterwards")
        if !planned.plan.isEmpty { describe(planned.plan) }
    }

    // MARK: - Scenario: a background run, called directly

    private func openCheck() async throws {
        log("== Opening the app checks every seam: unwatched ones are read, watched ones synced")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.sameOrderName)
        let appleId = try await applePlaylist(named: Self.sameOrderName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp])
        try await resetApple(appleId)
        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .spotifyToApple, appleOwned: true)
        try await env.apply(try await env.preview(first: true), trigger: .firstSync)
        _ = try await waitForApple(env, titles: ["Word Up"])

        let defaults = UserDefaults(suiteName: "antiphon-selftest-opencheck")!
        defaults.removePersistentDomain(forName: "antiphon-selftest-opencheck")
        let preferences = AppPreferences(defaults: defaults)
        preferences.wifiOnly = false
        preferences.pauseInLowPower = false
        preferences.quietHours = nil

        // Unwatched: read only. Right after a sync nothing is waiting (the
        // song just added on Apple Music must not count as a change).
        try env.setUnmonitored()
        let planner = SyncPlanner(modelContainer: env.container, spotifyClient: SpotifyAPIClient(),
                                  appleMusicManager: AppleMusicManager(), confidence: preferences.confidencePolicy)
        var waiting = try await planner.waitingChanges(pairId: env.pairId, since: Date())
        expect(waiting == 0, "just synced: nothing waiting (\(waiting))")

        _ = try await env.editor.add([seeds.midnightCity], to: spotifyId, on: .spotify)
        try env.setMonitored(lastSynced: Date().addingTimeInterval(-10 * 60))
        try env.setUnmonitored()
        let checks = SeamChecks()
        let coordinator = SyncCoordinator(modelContainer: env.container)
        await checks.runOnOpen(modelContainer: env.container, coordinator: coordinator, spotifySignedIn: true,
                               preferences: preferences)?.value
        let look = checks.looks[env.pairId]
        log("look: \(look.map { "\($0.waiting) waiting" } ?? "none")")
        expect(look?.waiting == 1, "unwatched: opening the app finds the new Spotify track waiting")
        var apple = try await env.appleTracks()
        expect(!apple.contains { $0.title.localizedCaseInsensitiveContains("Midnight City") }, "and doesn't add it")
        expect(checks.checking.isEmpty, "the card stops saying checking")

        // Watched, checked 10 minutes ago with an hourly interval: synced now anyway.
        try env.setMonitored(lastSynced: Date().addingTimeInterval(-10 * 60))
        let watchedChecks = SeamChecks()
        await watchedChecks.runOnOpen(modelContainer: env.container, coordinator: coordinator, spotifySignedIn: true,
                                      preferences: preferences)?.value
        apple = try await waitForApple(env, titles: ["Midnight City"])
        expect(apple.contains { $0.title.localizedCaseInsensitiveContains("Midnight City") }, "watched: opening the app adds it")
        let runs = try await env.repository.runs()
        expect(runs.first?.trigger == .monitor, "History shows it as a watching run")
        try env.setUnmonitored()
        waiting = try await planner.waitingChanges(pairId: env.pairId, since: Date())
        expect(waiting == 0, "afterwards nothing is waiting (\(waiting))")

        // Opened again a moment later: nothing is checked twice.
        try env.setMonitored(lastSynced: Date())
        let again = SeamChecks()
        await again.runOnOpen(modelContainer: env.container, coordinator: coordinator, spotifySignedIn: true,
                              preferences: preferences)?.value
        let runsAfter = try await env.repository.runs().count
        expect(again.looks.isEmpty && runsAfter == runs.count, "reopened within 5 min: nothing runs")
        defaults.removePersistentDomain(forName: "antiphon-selftest-opencheck")
    }

    private func monitorRun() async throws {
        log("== A background monitoring run (called directly; iOS decides when it really runs)")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.sameOrderName)
        let appleId = try await applePlaylist(named: Self.sameOrderName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp])
        try await resetApple(appleId)
        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .spotifyToApple, appleOwned: true)
        try await env.apply(try await env.preview(first: true), trigger: .firstSync)
        _ = try await waitForApple(env, titles: ["Word Up"])

        // The person's settings, in a throwaway suite.
        let defaults = UserDefaults(suiteName: "antiphon-selftest-monitor")!
        defaults.removePersistentDomain(forName: "antiphon-selftest-monitor")
        let preferences = AppPreferences(defaults: defaults)
        preferences.monitorIntervalMinutes = 60
        preferences.notifyNewTracks = .eachSync

        _ = try await env.editor.add([seeds.midnightCity], to: spotifyId, on: .spotify)
        try env.setMonitored(lastSynced: Date().addingTimeInterval(-10 * 60))
        var report = await MonitorRun.perform(modelContainer: env.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        log("synced 10 min ago, hourly: \(report.summary)")
        expect(report.due.isEmpty && report.results.isEmpty, "not due yet: nothing runs")

        try env.setMonitored(lastSynced: Date().addingTimeInterval(-61 * 60))
        preferences.wifiOnly = true
        report = await MonitorRun.perform(modelContainer: env.container, preferences: preferences, onWiFi: false, lowPower: false, post: false)
        expect(report.blocker == .notOnWiFi && report.results.isEmpty, "Wi-Fi only, on cellular: skipped")
        preferences.wifiOnly = false
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        preferences.quietHours = .init(startMinute: max(0, minute - 5), endMinute: min(24 * 60 - 1, minute + 5))
        report = await MonitorRun.perform(modelContainer: env.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        expect(report.blocker == .quietHours && report.results.isEmpty, "quiet hours: skipped")
        preferences.quietHours = nil

        report = await MonitorRun.perform(modelContainer: env.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        log("due: \(report.summary); messages \(report.messages.map { "\($0.kind.rawValue): \($0.body)" })")
        expect(report.due == [env.pairId], "due after its hour")
        expect(report.results.first?.status == .success && report.results.first?.tracksAdded == 1,
               "the run adds the new track (\(report.results.map { "\($0.status) +\($0.tracksAdded)" }))")
        expect(report.messages.contains { $0.kind == .newTracks && $0.body == "1 new track in self-test." }, "and says so")
        let apple = try await waitForApple(env, titles: ["Midnight City"])
        expect(apple.contains { $0.title.localizedCaseInsensitiveContains("Midnight City") }, "Midnight City is on Apple Music")
        let runs = try await env.repository.runs()
        expect(runs.first?.trigger == .monitor, "History shows it as watching")
        let fresh = try await env.repository.newTracks()
        expect(fresh.contains { $0.title.localizedCaseInsensitiveContains("Midnight City") }, "and it's under New tracks")
        // The widgets' snapshot follows the run (App Group, D4).
        if let folder = AppGroup.containerURL, let snapshot = WidgetSnapshot.read(from: folder) {
            log("snapshot: \(snapshot.seamCount) seams, \(snapshot.tracksInSync) in sync, new this week \(snapshot.newThisWeek.tracks) in \(snapshot.newThisWeek.playlists)")
            expect(Date().timeIntervalSince(snapshot.generatedAt) < 120 && snapshot.seamCount == 1 && snapshot.newThisWeek.tracks >= 1,
                   "the widget snapshot in the App Group describes this run")
        } else {
            expect(false, "the widget snapshot is in the App Group (\(AppGroup.identifier ?? "no group"))")
        }

        // Only the automatic band is added without asking: with the bar at
        // 100, anything less than a perfect match waits in Review.
        preferences.autoAddThreshold = 100
        _ = try await env.editor.add([seeds.faint, seeds.holocene], to: spotifyId, on: .spotify)
        try env.setMonitored(lastSynced: Date().addingTimeInterval(-61 * 60))
        report = await MonitorRun.perform(modelContainer: env.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        log("bar at 100: \(report.summary); messages \(report.messages.map { "\($0.kind.rawValue): \($0.body)" })")
        let appleAfter = try await env.appleTracks()
        for row in try env.rows(titled: ["Faint", "Holocene"]) {
            let onApple = appleAfter.contains { $0.title.localizedCaseInsensitiveContains(row.title) }
            guard let confidence = row.matchConfidence else {
                log("\(row.title): no match found (\(row.state.map { "\($0)" } ?? "-"))")
                continue
            }
            if confidence < 100 {
                expect(row.state == .needsReview && !onApple, "\(row.title) at \(confidence)%: waits in Review, not added")
            } else {
                log("\(row.title) matched at 100%, so the review band wasn't exercised by it")
                expect(row.state == .synced, "\(row.title) at 100%: added")
            }
        }
        expect(report.results.first?.status != .failed, "the run didn't fail (\(report.results.map { "\($0.status)" }))")

        // Close matches are asked one by one, with the answer as buttons (9.01).
        log("questions: \(report.questions.map { "\($0.title) | \($0.body) | \($0.category.actions.map(\.title))" })")
        if let question = report.questions.first(where: { $0.body.localizedCaseInsensitiveContains("Faint") }) {
            expect(!report.messages.contains { $0.kind == .decide }, "the question replaces the summary")
            let answered = await QuestionNotifications.answer(.useMatch, userInfo: question.userInfo,
                                                              review: env.repository, sync: env.sync)
            expect(answered == .answered, "tapping \(question.category.actions.last?.title ?? "use") answers it")
            let apple = try await waitForApple(env, titles: ["Faint"])
            expect(apple.contains { $0.title.localizedCaseInsensitiveContains("Faint") }, "and Faint is on Apple Music")
            let again = await QuestionNotifications.answer(.useMatch, userInfo: question.userInfo,
                                                           review: env.repository, sync: env.sync)
            expect(again == .gone, "a question already answered does nothing")
        } else if (try env.rows(titled: ["Faint"]).first?.matchConfidence ?? 100) < 100 {
            expect(false, "Faint waiting in Review is asked as a question")
        }

        // iOS accepts the background refresh that runs monitoring (it needs the
        // "fetch" background mode, which 1.2.1 had dropped). When it runs is iOS's call.
        BackgroundTaskManager.scheduleBackgroundRefresh(modelContainer: env.container)
        let pending = await BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier)
        expect(pending.contains(AppConstants.BackgroundTasks.playlistRefreshIdentifier),
               "iOS has the background check scheduled (\(pending))")

        // Sync all from the widget: every seam, now. Even one set to "Only
        // when I ask" and synced a moment ago (no cooldown).
        try env.setMonitored(lastSynced: Date())
        try env.setUnmonitored()
        // A track new to both sides, so there's something to add.
        let pumpIt = try await spotifyTrack("track:Pump It artist:Black Eyed Peas", album: "Monkey Business")
        _ = try await env.editor.add([pumpIt], to: spotifyId, on: .spotify)
        preferences.autoAddThreshold = ConfidencePolicy.defaultAutoAddThreshold
        let syncAll = await SyncAllRunner.run(modelContainer: env.container, preferences: preferences)
        log("Sync all: \(syncAll.map { "\($0.status) +\($0.tracksAdded)" })")
        expect(syncAll.count == 1 && syncAll.first?.tracksAdded == 1,
               "Sync all syncs the seam that isn't monitored and was just synced, adding Pump It")
        let afterSyncAll = try await waitForApple(env, titles: ["Pump It"])
        expect(afterSyncAll.contains { $0.title.localizedCaseInsensitiveContains("Pump It") }, "and Pump It reaches Apple Music")
        expect(try await env.repository.runs().first?.trigger == .widget, "History shows it as started from the widget")

        // Two-way Mirror: a removal on Spotify is carried out on Apple Music
        // in the background, unless "Removals in the background" is off.
        log("== Background removals in a two-way Mirror seam")
        preferences.autoAddThreshold = ConfidencePolicy.defaultAutoAddThreshold
        try await resetSpotify(spotifyId, to: [seeds.wordUp, seeds.faint])
        try await resetApple(appleId)
        let twoWay = try Env(spotifyId: spotifyId, appleId: appleId, direction: .bidirectional, appleOwned: true)
        try await twoWay.apply(try await twoWay.preview(first: true), trigger: .firstSync)
        _ = try await waitForApple(twoWay, titles: ["Word Up", "Faint"])
        try twoWay.setRemovalPolicy(.mirror)
        try await twoWay.editor.remove([seeds.faint], from: spotifyId, on: .spotify)

        preferences.removeInBackground = false
        try twoWay.setMonitored(lastSynced: Date().addingTimeInterval(-61 * 60))
        report = await MonitorRun.perform(modelContainer: twoWay.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        log("switched off: \(report.summary)")
        let kept = try await twoWay.appleTracks()
        expect(report.results.first?.status != .failed, "switched off: the run didn't fail")
        expect(kept.contains { $0.title.localizedCaseInsensitiveContains("Faint") }, "switched off: Faint stays on Apple Music")

        preferences.removeInBackground = true
        try twoWay.setMonitored(lastSynced: Date().addingTimeInterval(-61 * 60))
        report = await MonitorRun.perform(modelContainer: twoWay.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        log("switched on: \(report.summary)")
        let after = try await twoWay.appleTracks()
        expect(!after.contains { $0.title.localizedCaseInsensitiveContains("Faint") } && after.contains { $0.title.localizedCaseInsensitiveContains("Word Up") },
               "switched on: the background run removes Faint from Apple Music, Word Up stays (\(after.map(\.title)))")
        let removalRun = try await twoWay.repository.runs().first
        expect(removalRun?.trigger == .monitor, "History shows the removal as a watching run")
        defaults.removePersistentDomain(forName: "antiphon-selftest-monitor")
    }

    // MARK: - Scenario: a question answered from its notification (by name)

    private func askOnLockScreen() async throws {
        log("== A close match asked as a notification, answered with its button while the app is in the background")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.sameOrderName)
        let appleId = try await applePlaylist(named: Self.sameOrderName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp])
        try await resetApple(appleId)
        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .spotifyToApple, appleOwned: true)
        try await env.apply(try await env.preview(first: true), trigger: .firstSync)
        _ = try await waitForApple(env, titles: ["Word Up"])

        let defaults = UserDefaults(suiteName: "antiphon-selftest-ask")!
        defaults.removePersistentDomain(forName: "antiphon-selftest-ask")
        let preferences = AppPreferences(defaults: defaults)
        preferences.autoAddThreshold = 100
        _ = try await env.editor.add([seeds.faint], to: spotifyId, on: .spotify)
        try env.setMonitored(lastSynced: Date().addingTimeInterval(-61 * 60))
        let report = await MonitorRun.perform(modelContainer: env.container, preferences: preferences, onWiFi: true, lowPower: false, post: false)
        guard var question = report.questions.first(where: { $0.body.localizedCaseInsensitiveContains("Faint") }) else {
            expect(false, "Faint is asked as a question (\(report.questions.map(\.body)))")
            return
        }
        // The answer runs against this test's store, not the app's.
        SelfTestStore.container.withLock { $0 = env.container }
        defer { SelfTestStore.container.withLock { $0 = nil } }
        question.userInfo["selftest"] = "1"
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        log("notifications allowed: \(settings.authorizationStatus == .authorized), banners \(settings.alertSetting == .enabled), Notification Centre \(settings.notificationCenterSetting == .enabled)")
        await MonitorRun.ask([question])
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
        log("delivered: \(delivered.contains(question.id))")
        let button = question.category.actions.last?.title ?? "Use this version"
        log("Posted: \(question.title) \(question.body)")
        log("Now go to the Home Screen, open Notification Centre, long-press the Antiphon question and tap \"\(button)\". Then open this app again.")
        let apple = try await waitForApple(env, titles: ["Faint"])
        expect(apple.contains { $0.title.localizedCaseInsensitiveContains("Faint") }, "the button added Faint to Apple Music")
        // The answer finishes after Apple Music lists the track (anchoring).
        var left = try await env.repository.reviewItems(seamId: env.pairId)
        let start = Date()
        while !left.isEmpty, Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .seconds(2))
            left = try await env.repository.reviewItems(seamId: env.pairId)
        }
        expect(left.isEmpty, "and the question is answered (\(left.count) left in Review)")
        defaults.removePersistentDomain(forName: "antiphon-selftest-ask")
    }

    // MARK: - Scenario: the Live Activity (by name)

    private func liveActivity() async throws {
        log("== Live Activity: Lock Screen and Dynamic Island, with simulated progress")
        expect(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities are allowed for Antiphon")
        // Started as if the sync had already run 20 seconds.
        let live = SyncLiveActivity(startedAt: Date().addingTimeInterval(-SyncActivityPolicy.startAfter))
        let total = 35
        log("Go to the Home Screen to see the Dynamic Island (long-press it to expand); lock the phone or pull down for the Lock Screen view. Come back in about 2 minutes.")
        for done in stride(from: 0, through: total, by: 1) {
            let phase: SyncPhase = done < 15 ? .matching : .adding(platformName: "Apple Music")
            await live.show(SyncActivityContent.state(seamName: "Workout Mix 2026",
                                                      progress: SyncProgress(totalTracks: total, completedTracks: done, failedTracks: 0, phase: phase)))
            if done == 0 {
                expect(live.isActive && Activity<SyncActivityAttributes>.activities.count == 1, "iOS shows the Live Activity")
            }
            try await Task.sleep(for: .seconds(3.5))
        }
        await live.finish(SyncActivityContent.finished(seamName: "Workout Mix 2026",
                                                       result: SyncResult(pairId: UUID(), status: .success, tracksAdded: 35)))
        expect(!live.isActive, "it ends with the result (\"Synced · 35 added\"), shown for a few minutes")
    }

    // MARK: - Scenario: undo a two-way sync

    private func undoTwoWay() async throws {
        log("== Undo a two-way sync, both playlists Antiphon's")
        let seeds = try await spotifySeeds()
        let spotifyId = try await spotifyPlaylist(named: Self.undoName)
        let appleId = try await applePlaylist(named: Self.undoName, createIfMissing: true)
        try await resetSpotify(spotifyId, to: [seeds.wordUp, seeds.faint])
        try await resetApple(appleId)

        let env = try Env(spotifyId: spotifyId, appleId: appleId, direction: .bidirectional, appleOwned: true)
        try await env.apply(try await env.preview(first: true), trigger: .firstSync)
        _ = try await waitForApple(env, titles: ["Word Up", "Faint"])
        try await env.apply(try await env.preview(), trigger: .manual)

        // One new track on each side, synced across in one run.
        _ = try await env.editor.add([seeds.holocene], to: spotifyId, on: .spotify)
        let pumpIt = try await appleCatalogTrack("Pump It Black Eyed Peas", album: "Monkey Business")
        _ = try await env.editor.add([pumpIt], to: appleId, on: .appleMusic)
        _ = try await waitForApple(env, titles: ["Pump It"])
        var planned = try await env.preview()
        describe(planned.plan)
        try await env.apply(planned, trigger: .manual)
        _ = try await waitForApple(env, titles: ["Holocene"])
        var spotify = try await env.editor.tracks(in: spotifyId, on: .spotify).map(\.title)
        expect(spotify.contains { $0.localizedCaseInsensitiveContains("Pump It") }, "Pump It reached Spotify (\(spotify))")

        let runs = try await env.repository.runs()
        guard let run = runs.first(where: { $0.count(.add, on: .spotify) == 1 && $0.count(.add, on: .appleMusic) == 1 }) else {
            throw SelfTestError("no run with the two adds")
        }
        log("history: \(runs.map { ActivityCopy.line($0) })")
        expect(run.canUndo, "the sync can be undone")
        let undoPlan = try await env.sync.undoPreview(runId: run.id)
        log("undo says: \(undoPlan.summary) \(undoPlan.guidedNote ?? "")")
        let removals = undoPlan.operations.filter { $0.kind == .remove }.count
        let moves = undoPlan.operations.count - removals
        expect(removals == 2 && moves == run.changes.filter { $0.kind == .move }.count && undoPlan.guided.isEmpty && undoPlan.skipped.isEmpty,
               "undo plans two removals and puts moved tracks back (\(removals) removals, \(moves) moves, \(undoPlan.guided.count) guided, \(undoPlan.skipped.count) skipped)")

        let outcome = try await env.sync.undo(runId: run.id)
        log("undo landed \(outcome.landed.map { "\($0.track.title) on \($0.platform.rawValue)" }), guided \(outcome.guided.count), skipped \(outcome.skipped.count)")
        expect(outcome.landed.filter { $0.kind == .remove }.count == 2, "both removals landed")

        spotify = try await env.editor.tracks(in: spotifyId, on: .spotify).map(\.title)
        expect(!spotify.contains { $0.localizedCaseInsensitiveContains("Pump It") }, "Pump It is gone from Spotify (\(spotify))")
        let start = Date()
        var apple = try await env.appleTracks().map(\.title)
        while apple.contains(where: { $0.localizedCaseInsensitiveContains("Holocene") }), Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(for: .seconds(3))
            apple = try await env.appleTracks().map(\.title)
        }
        expect(!apple.contains { $0.localizedCaseInsensitiveContains("Holocene") }, "Holocene is gone from Apple Music (\(apple))")
        expect(apple.contains { $0.localizedCaseInsensitiveContains("Pump It") } && spotify.contains { $0.localizedCaseInsensitiveContains("Holocene") },
               "the tracks stay where the person added them")

        let after = try await env.repository.runs()
        expect(after.first { $0.id == run.id }?.undoneAt != nil, "the run is marked undone")
        expect(after.contains { $0.trigger == .undo && $0.undoOfRunId == run.id }, "the undo is its own entry in history")
        expect(!(after.first { $0.id == run.id }?.canUndo ?? true), "an undone sync can't be undone twice")

        planned = try await env.preview()
        describe(planned.plan)
        expect(planned.plan.isEmpty, "the next sync doesn't bring the undone tracks back or ask about them")
        try await env.apply(planned, trigger: .manual)
        planned = try await env.preview()
        expect(planned.plan.isEmpty, "still settled a sync later")
    }

    // MARK: - Read only: Library, availability, search

    private func libraryReadOnly() async throws {
        log("== Library and search (read only)")
        let library = LiveLibraryService(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        let spotify = try await library.playlists(on: .spotify)
        let apple = try await library.playlists(on: .appleMusic)
        log("Spotify: \(spotify.count) playlists, \(spotify.filter(\.isOwn).count) own, \(spotify.filter(\.isCollaborative).count) collaborative, \(spotify.filter { $0.blockedReason != nil }.count) blocked")
        log("Apple Music: \(apple.count) playlists, \(apple.filter(\.isOwn).count) own; not own: \(apple.filter { !$0.isOwn }.prefix(5).map { "\($0.name) (\($0.detail))" })")
        expect(!spotify.isEmpty && !apple.isEmpty, "both libraries load")
        let ownApple = Set(apple.filter(\.isOwn).map(\.name))
        expect([Self.ownedName, Self.userOwnedAppleName].allSatisfy(ownApple.contains),
               "Apple Music playlists the person or Antiphon made count as their own")

        let repository = SwiftDataSeamRepository(modelContainer: SharedModelContainer.container)
        let seams = try await repository.seams()
        let items = LibraryGrid.items(spotify: spotify, appleMusic: apple, seams: seams)
        let counts = LibraryGrid.counts(items, scope: .both)
        log("grid: no twin \(counts[.noTwin] ?? 0), in a seam \(counts[.inSeam] ?? 0), made by me \(counts[.madeByMe] ?? 0); seams \(seams.count)")
        expect(seams.isEmpty || (counts[.inSeam] ?? 0) > 0, "seamed playlists are recognized in the grid")

        let availability = LiveAvailabilityService()
        for (platform, list) in [(Platform.spotify, spotify), (.appleMusic, apple)] {
            guard let playlist = list.first(where: { $0.name == Self.ownedName }) else { continue }
            let entries = try await library.entries(of: playlist)
            let start = Date()
            let report = try await availability.check(entries.map(\.track), on: platform.other) { _ in }
            log("\(platform.rawValue) \(Self.ownedName) → \(platform.other.rawValue): \(PlaylistCopy.availability(report, on: platform.other)) (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
            expect(report.isComplete && report.available.count == entries.count,
                   "every track of the \(platform.rawValue) self-test playlist is found on \(platform.other.rawValue)")
        }

        // Collaborator names: counts only, no names in the log.
        if let shared = spotify.first(where: { $0.isCollaborative && $0.blockedReason == nil }) {
            let entries = try await library.entries(of: shared)
            let ids = Set(entries.filter { $0.addedBy == .collaborator }.compactMap(\.addedByUserId))
            let names = await library.displayNames(for: ids)
            log("collaborative playlist: \(entries.count) tracks, \(entries.filter { $0.addedBy == .you }.count) by you, \(ids.count) collaborators, \(names.count) names found")
            expect(ids.isEmpty || !names.isEmpty, "collaborators' names can be looked up")
        } else {
            log("no collaborative Spotify playlist to check names on")
        }

        // Onboarding's twin scan, read only: nothing is linked.
        let onboarding = OnboardingModel(library: library, seams: repository, appleMusic: LiveAppleMusicAccountReader(),
                                         requestAppleMusic: {})
        let scanStart = Date()
        await onboarding.scan()
        log("twins: \(onboarding.suggestions.count) in \(String(format: "%.1f", Date().timeIntervalSince(scanStart))) s, \(onboarding.checked.count) checked; \(onboarding.restLine ?? "-")")
        for suggestion in onboarding.suggestions.prefix(8) {
            log("  \(suggestion.title): \(suggestion.detail)\(onboarding.checked.contains(suggestion.id) ? " ✓" : "")")
        }
        let selfTestTwin = onboarding.suggestions.first { $0.title == Self.undoName }
        expect(selfTestTwin != nil && onboarding.checked.contains(selfTestTwin!.id),
               "the self-test playlists (same name, same tracks) are found as twins and checked")

        let index = try await repository.indexedTracks()
        log("search index: \(index.count) tracks in \(Set(index.map(\.seam.id)).count) seams")
        expect(seams.isEmpty || !index.isEmpty, "the search index holds the seams' tracks")
        if let sample = index.first {
            let hits = LibrarySearch.tracks(sample.title, in: index)
            log("search “\(sample.title)”: \(hits.map { "\($0.title) — Spotify: \(LibrarySearch.sideText($0.spotify, on: .spotify)), Apple Music: \(LibrarySearch.sideText($0.appleMusic, on: .appleMusic))" })")
            expect(hits.contains { $0.title == sample.title }, "searching a seam's track finds it")
        }
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
        init(spotifyId: String, appleId: String, direction: SyncDirection, appleOwned: Bool,
             placement: TrackPlacement? = nil) throws {
            let url = URL.applicationSupportDirectory.appending(path: "selftest-\(UUID().uuidString).store")
            container = try SharedModelContainer.make(url: url)
            let context = ModelContext(container)
            let pair = SyncPair(spotifyPlaylistId: spotifyId, spotifyPlaylistName: "self-test",
                                appleMusicPlaylistId: appleId, appleMusicPlaylistName: "self-test", syncDirection: direction)
            pair.spotifyCreatedByAntiphon = true
            pair.appleMusicCreatedByAntiphon = appleOwned
            pair.newTrackPlacement = placement
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

        /// The seam's rows whose titles contain one of `titles`.
        @MainActor
        func rows(titled titles: [String]) throws -> [(title: String, state: TrackSyncState?, matchConfidence: Int?)] {
            try ModelContext(container).fetch(FetchDescriptor<CachedTrack>())
                .filter { row in row.syncPair?.id == pairId && titles.contains { row.title.localizedCaseInsensitiveContains($0) } }
                .map { ($0.title, $0.syncState, $0.matchConfidence) }
        }

        @MainActor
        func setUnmonitored() throws {
            let context = ModelContext(container)
            guard let pair = try context.fetch(FetchDescriptor<SyncPair>()).first(where: { $0.id == pairId }) else {
                throw SelfTestError("no seam")
            }
            pair.isMonitored = false
            try context.save()
        }

        @MainActor
        func setRemovalPolicy(_ policy: RemovalPolicy) throws {
            let context = ModelContext(container)
            guard let pair = try context.fetch(FetchDescriptor<SyncPair>()).first(where: { $0.id == pairId }) else {
                throw SelfTestError("no seam")
            }
            pair.removalPolicy = policy
            try context.save()
        }

        /// Monitored, as if last synced at `lastSynced`.
        @MainActor
        func setMonitored(lastSynced: Date) throws {
            let context = ModelContext(container)
            guard let pair = try context.fetch(FetchDescriptor<SyncPair>()).first(where: { $0.id == pairId }) else {
                throw SelfTestError("no seam")
            }
            pair.isMonitored = true
            pair.monitorIntervalMinutes = nil
            pair.lastSyncedAt = lastSynced
            try context.save()
        }

        /// A one-sided row that wasn't found after every try.
        @MainActor
        func markUnavailable(title: String, lastTried: Date) throws {
            let context = ModelContext(container)
            guard let row = try context.fetch(FetchDescriptor<CachedTrack>())
                .first(where: { $0.syncPair?.id == pairId && $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw SelfTestError("no row for \(title)")
            }
            row.appleMusicTrackId = nil
            row.source = .spotify
            row.syncState = .failed
            row.retryCount = PlanBuilder.maxRetries
            row.lastSyncAttempt = lastTried
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

    /// Moves a track to the second place, like a person dragging it there.
    private func moveToSecond(_ env: Env, title: String, on platform: Platform) async throws {
        try await move(env, title: title, to: 1, on: platform)
    }

    private func move(_ env: Env, title: String, to position: Int, on platform: Platform) async throws {
        let playlistId = platform == .spotify ? env.spotifyId : env.appleId
        var ids = try await env.editor.tracks(in: playlistId, on: platform).map { ($0.id, $0.title) }
        guard let index = ids.firstIndex(where: { $0.1.localizedCaseInsensitiveContains(title) }) else {
            throw SelfTestError("\(title) isn't on \(platform.rawValue) to move")
        }
        let moved = ids.remove(at: index)
        ids.insert(moved, at: min(position, ids.count))
        try await env.editor.reorder(playlistId, on: platform, to: ids.map(\.0))
        log("moved \(title) to position \(position + 1) on \(platform.rawValue): \(ids.map(\.1))")
    }

    /// Tracks on both sides are in the same order on both sides.
    private func checkOrder(_ env: Env, _ label: String) async throws {
        let spotify = try await env.editor.tracks(in: env.spotifyId, on: .spotify).map(\.title.normalizedForMatching)
        let apple = try await env.appleTracks().map(\.title.normalizedForMatching)
        let shared = Set(spotify).intersection(apple)
        let spotifyOrder = spotify.filter(shared.contains), appleOrder = apple.filter(shared.contains)
        expect(spotifyOrder == appleOrder, "same order on both sides \(label): Spotify \(spotifyOrder) / Apple Music \(appleOrder)")
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
