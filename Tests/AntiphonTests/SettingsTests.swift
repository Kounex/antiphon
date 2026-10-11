import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Antiphon

@Suite("Monitoring schedule and gates")
struct MonitoringTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-10-14 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_990_000)

    private func seam(_ interval: Int?, lastSyncedMinutesAgo: Double?) -> MonitorSchedule.Seam {
        MonitorSchedule.Seam(id: UUID(), intervalMinutes: interval, lastSyncedAt: lastSyncedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) })
    }

    @Test("A seam is due once its own interval (or the default) has passed")
    func due() {
        let hourly = seam(60, lastSyncedMinutesAgo: 70)
        let daily = seam(1440, lastSyncedMinutesAgo: 70)
        let byDefault = seam(nil, lastSyncedMinutesAgo: 20)
        let due = MonitorSchedule.due([hourly, daily, byDefault], defaultMinutes: 15, now: now)
        #expect(due == [hourly.id, byDefault.id])
    }

    @Test("The next wake-up is the soonest seam, never sooner than 15 minutes")
    func next() {
        let soon = seam(60, lastSyncedMinutesAgo: 50)
        let later = seam(1440, lastSyncedMinutesAgo: 10)
        #expect(MonitorSchedule.nextBegin([soon, later], defaultMinutes: 15, now: now) == now.addingTimeInterval(15 * 60))
        let hourOff = seam(720, lastSyncedMinutesAgo: 660)
        #expect(MonitorSchedule.nextBegin([hourOff], defaultMinutes: 15, now: now) == now.addingTimeInterval(60 * 60))
        #expect(MonitorSchedule.nextBegin([], defaultMinutes: 15, now: now) == nil)
    }

    @Test("Gates: Wi-Fi only, Low Power Mode, quiet hours across midnight")
    func gates() {
        var settings = MonitorGates.Settings(wifiOnly: true, pauseInLowPower: true, quietHours: nil)
        #expect(MonitorGates.blocker(settings, onWiFi: false, lowPower: false, now: now, calendar: Self.calendar) == .notOnWiFi)
        #expect(MonitorGates.blocker(settings, onWiFi: true, lowPower: true, now: now, calendar: Self.calendar) == .lowPower)
        #expect(MonitorGates.blocker(settings, onWiFi: true, lowPower: false, now: now, calendar: Self.calendar) == nil)
        settings = MonitorGates.Settings(wifiOnly: false, pauseInLowPower: false, quietHours: .init(startMinute: 23 * 60, endMinute: 7 * 60))
        let lateNight = Self.calendar.date(bySettingHour: 23, minute: 30, second: 0, of: now)!
        let early = Self.calendar.date(bySettingHour: 6, minute: 59, second: 0, of: now)!
        let morning = Self.calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        #expect(MonitorGates.blocker(settings, onWiFi: false, lowPower: true, now: lateNight, calendar: Self.calendar) == .quietHours)
        #expect(MonitorGates.blocker(settings, onWiFi: false, lowPower: true, now: early, calendar: Self.calendar) == .quietHours)
        #expect(MonitorGates.blocker(settings, onWiFi: false, lowPower: true, now: morning, calendar: Self.calendar) == nil)
    }
}

@Suite("Notifications after a background run")
struct MonitorNotificationTests {
    private let drive = UUID()

    private func outcome(added: Int = 0, review: Int = 0, failed: String? = nil) -> MonitorNotifications.SeamOutcome {
        MonitorNotifications.SeamOutcome(seamId: drive, seamName: "Late Night Drive", added: added,
                                         newQuestions: review, failure: failed)
    }

    @Test("Each category speaks only when it's on")
    func categories() {
        var prefs = MonitorNotifications.Preferences(decide: true, breaks: true, newTracks: .eachSync)
        let messages = MonitorNotifications.messages([outcome(added: 4, review: 2), outcome(failed: "Spotify needs you to sign in again.")], prefs)
        #expect(messages.map(\.kind) == [.decide, .breaks, .newTracks])
        #expect(messages.first?.body == "Late Night Drive has 2 tracks waiting for your call.")
        #expect(messages.last?.body == "4 new tracks in Late Night Drive.")

        prefs = MonitorNotifications.Preferences(decide: false, breaks: false, newTracks: .dailySummary)
        #expect(MonitorNotifications.messages([outcome(added: 4, review: 2)], prefs).isEmpty)
    }

    @Test("The daily summary counts today's tracks; nothing new, no summary")
    func summary() {
        #expect(MonitorNotifications.dailySummary(tracks: 12, seams: 3) == "Antiphon synced 12 new tracks across 3 seams today.")
        #expect(MonitorNotifications.dailySummary(tracks: 1, seams: 1) == "Antiphon synced 1 new track today.")
        #expect(MonitorNotifications.dailySummary(tracks: 0, seams: 0) == nil)
    }
}

@Suite("Matching preferences")
struct MatchingPreferenceTests {
    private func track(_ title: String, explicit: Bool? = nil, platform: Platform = .spotify) -> CatalogTrack {
        CatalogTrack(platform: platform, id: title, title: title, artist: "Artist", durationMs: 200_000, isExplicit: explicit)
    }

    @Test("Explicit or clean: same as source by default, or always one of them")
    func explicitPreference() {
        let cleanSource = track("Song", explicit: false), explicitCandidate = track("Song", explicit: true, platform: .appleMusic)
        let same = ConfidenceScorer.score(source: cleanSource, candidate: explicitCandidate)
        #expect(same.confidence < 90 && same.reason == .versionDifference)
        let preferExplicit = ConfidenceScorer.score(source: cleanSource, candidate: explicitCandidate,
                                                    preferences: VersionPreferences(explicit: .explicit))
        #expect(preferExplicit.confidence >= 90)
        let preferClean = ConfidenceScorer.score(source: track("Song", explicit: true), candidate: track("Song", explicit: false, platform: .appleMusic),
                                                 preferences: VersionPreferences(explicit: .clean))
        #expect(preferClean.confidence >= 90)
    }

    @Test("Live versions are never used unless allowed; then they're close matches, never automatic")
    func live() {
        let source = track("Song"), live = track("Song (Live)", platform: .appleMusic)
        #expect(ConfidenceScorer.score(source: source, candidate: live).confidence < ConfidencePolicy.reviewFloor)
        let allowed = ConfidenceScorer.score(source: source, candidate: live, preferences: VersionPreferences(allowLive: true))
        #expect(allowed.confidence >= ConfidencePolicy.reviewFloor && allowed.confidence < 90)
        // A live source matches a live candidate either way.
        #expect(ConfidenceScorer.score(source: track("Song (Live)"), candidate: live).confidence >= 90)
    }

    @Test("Radio edits count as the same recording only when allowed")
    func radioEdits() {
        let source = track("Song"), edit = track("Song (Radio Edit)", platform: .appleMusic)
        #expect(ConfidenceScorer.score(source: source, candidate: edit).confidence < 90)
        #expect(ConfidenceScorer.score(source: source, candidate: edit, preferences: VersionPreferences(allowRadioEdits: true)).confidence >= 90)
    }

    @Test("The threshold is grounded in history: how many tracks it would have asked about")
    func wouldAsk() {
        let confidences = [100, 100, 97, 92, 88, 84, 72]
        #expect(MatchingCopy.wouldAsk(confidences, threshold: 90) == "Last month this would have asked about 3 of 7 tracks.")
        #expect(MatchingCopy.wouldAsk(confidences, threshold: 98) == "Last month this would have asked about 5 of 7 tracks.")
        #expect(MatchingCopy.wouldAsk([], threshold: 90) == "Once Antiphon has matched some tracks, this shows how often it would ask.")
    }

    @Test("Unavailable tracks are checked again on the chosen cadence")
    func recheck() {
        let now = Date()
        let weekOld = now.addingTimeInterval(-8 * 86_400)
        #expect(AvailabilityRecheck.isDue(retryCount: 3, lastAttempt: weekOld, cadence: .weekly, now: now))
        #expect(!AvailabilityRecheck.isDue(retryCount: 3, lastAttempt: now.addingTimeInterval(-86_400), cadence: .weekly, now: now))
        #expect(AvailabilityRecheck.isDue(retryCount: 3, lastAttempt: now.addingTimeInterval(-86_400 - 60), cadence: .daily, now: now))
        #expect(!AvailabilityRecheck.isDue(retryCount: 3, lastAttempt: weekOld, cadence: .never, now: now))
        #expect(AvailabilityRecheck.isDue(retryCount: 3, lastAttempt: nil, cadence: .weekly, now: now))
        // Still within the first tries: due anyway.
        #expect(AvailabilityRecheck.isDue(retryCount: 1, lastAttempt: now, cadence: .never, now: now))
    }
}

@Suite("Settings copy")
struct SettingsCopyTests {
    @Test("Rows show their current values")
    func values() {
        #expect(SettingsCopy.newSeamDefaults(.keep) == "Add only")
        #expect(SettingsCopy.newSeamDefaults(.mirror) == "Mirror exactly")
        #expect(SettingsCopy.monitoring(isOn: true, minutes: 15) == "15 min")
        #expect(SettingsCopy.monitoring(isOn: true, minutes: 720) == "Twice a day")
        #expect(SettingsCopy.monitoring(isOn: false, minutes: 15) == "Off")
        #expect(SettingsCopy.backgroundRemovals(true)
                == "When a seam is set to remove a track on the other side too, background checks do it without a preview. Each removal is in History and can be undone. Apple Music playlists you made yourself are the exception: apps can't remove from them.")
        #expect(SettingsCopy.backgroundRemovals(false)
                == "Removals wait until you sync and check the preview. New tracks are still added in the background.")
        #expect(SettingsCopy.header(seams: 9, tracksInSync: 1284, locale: Locale(identifier: "en_US")) == "9 seams · 1,284 tracks in sync")
    }

    @Test("Disconnecting says what happens before you tap")
    func disconnect() {
        #expect(SettingsCopy.disconnectEffect(seams: 9)
                == "Syncing stops until you connect again. Your playlists stay exactly as they are on both services.")
        #expect(SettingsCopy.disconnectEffect(seams: 0) == "Your playlists stay exactly as they are.")
    }

    @Test("The Spotify account line: plan if Spotify says, then since when")
    func spotifyLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let march3 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 12))!
        let locale = Locale(identifier: "en_GB"), utc = TimeZone(identifier: "UTC")!
        #expect(SettingsCopy.spotifyLine(product: "premium", signedInAt: march3, locale: locale, timeZone: utc) == "Premium · signed in since 3 March 2026")
        #expect(SettingsCopy.spotifyLine(product: nil, signedInAt: march3, locale: locale, timeZone: utc) == "Signed in since 3 March 2026")
        #expect(SettingsCopy.spotifyLine(product: nil, signedInAt: nil, locale: locale) == nil)
    }

    @Test("Quiet hours read as a range")
    func quietHours() {
        #expect(SettingsCopy.quietHours(.init(startMinute: 23 * 60, endMinute: 7 * 60)) == "23:00–07:00")
    }
}

@Suite("After a background run")
struct MonitorOutcomeTests {
    @Test("Outcomes per seam: tracks added, new questions, failures in words")
    func outcomes() {
        let drive = PreviewFixtures.lateNightDrive
        var after = drive
        after = SeamSummary(id: drive.id, spotify: drive.spotify, appleMusic: drive.appleMusic, direction: drive.direction,
                            isMonitored: true, isPaused: false, monitorIntervalMinutes: 15, lastCheckedAt: Date(), lastResult: .success,
                            counts: SeamCounts(synced: 52, review: 5, missing: 1, total: 58))
        let garden = PreviewFixtures.gardenSundays
        let results = [SyncResult(pairId: drive.id, status: .success, tracksAdded: 4),
                       SyncResult(pairId: garden.id, status: .failed, message: "Spotify needs you to sign in again.")]
        let outcomes = MonitorRun.outcomes(before: [drive, garden], after: [after, garden], results: results)
        #expect(outcomes.map(\.seamName) == ["Late Night Drive", "Garden Sundays"])
        #expect(outcomes[0].added == 4 && outcomes[0].newQuestions == 2 && outcomes[0].failure == nil)
        #expect(outcomes[1].failure == "Spotify needs you to sign in again.")
    }
}

@Suite("Settings store", .serialized)
@MainActor
struct SettingsStoreTests {
    private func seeded() throws -> ModelContainer {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let made = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Late Night Drive",
                            appleMusicPlaylistId: "am", appleMusicPlaylistName: "Late Night Drive", syncDirection: .spotifyToApple)
        made.appleMusicCreatedByAntiphon = true
        let theirs = SyncPair(spotifyPlaylistId: "sp2", spotifyPlaylistName: "Run Club",
                              appleMusicPlaylistId: "am2", appleMusicPlaylistName: "Running", syncDirection: .bidirectional)
        context.insert(made)
        context.insert(theirs)
        for (n, confidence) in [100, 97, 84].enumerated() {
            let row = CachedTrack(isrc: "ISRC\(n)", title: "Track \(n)", artist: "A", source: .spotify)
            row.spotifyTrackUri = "spotify:track:\(n)"
            row.appleMusicTrackId = "i.\(n)"
            row.source = .both
            row.syncState = .synced
            row.matchConfidence = confidence
            row.lastSyncAttempt = Date().addingTimeInterval(-Double(n) * 86_400)
            row.syncPair = made
            context.insert(row)
        }
        let old = CachedTrack(isrc: "OLD", title: "Old", artist: "A", source: .spotify)
        old.matchConfidence = 50
        old.syncState = .failed
        old.lastSyncAttempt = Date().addingTimeInterval(-40 * 86_400)
        old.syncPair = theirs
        context.insert(old)
        let log = SyncLog(action: .manualSync, tracksAdded: 1)
        log.syncPair = made
        log.trigger = .manual
        context.insert(log)
        let change = SyncChange(platform: .appleMusic, kind: .add,
                                track: CatalogTrack(platform: .appleMusic, id: "i.0", title: "Track, \"0\"", artist: "A"), confidence: 100, reason: .isrc)
        change.run = log
        context.insert(change)
        try context.save()
        return container
    }

    @Test("Usage: seams, tracks in sync, playlists Antiphon made per side")
    func usage() async throws {
        let usage = try await SwiftDataSeamRepository(modelContainer: try seeded()).usage()
        #expect(usage == AccountUsage(seams: 2, tracksInSync: 3, madeOnSpotify: 0, madeOnAppleMusic: 1))
    }

    @Test("Match confidences from the last 30 days")
    func confidences() async throws {
        let values = try await SwiftDataSeamRepository(modelContainer: try seeded()).recentConfidences(days: 30)
        #expect(values.sorted() == [84, 97, 100])
    }

    @Test("History exports as CSV, quoted where needed")
    func export() async throws {
        let csv = try await SwiftDataSeamRepository(modelContainer: try seeded()).historyCSV()
        let lines = csv.split(separator: "\n")
        #expect(lines.first == "date,seam,started by,change,service,title,artist,confidence")
        #expect(lines.count == 2)
        #expect(lines[1].contains(",Late Night Drive,manual,add,Apple Music,\"Track, \"\"0\"\"\",A,100"))
    }

    @Test("Reset removes every seam, run and change")
    func reset() async throws {
        let container = try seeded()
        try await SwiftDataSeamRepository(modelContainer: container).resetAll()
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<SyncPair>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CachedTrack>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SyncLog>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SyncChange>()) == 0)
    }
}

@Suite("Appearance")
struct AppearanceTests {
    @Test("System follows iOS; light and dark override it")
    func schemes() {
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(AppAppearance.allCases.map(\.interfaceStyle) == [.unspecified, .light, .dark])
    }

    @Test("The Home Screen icon follows: System keeps the adaptive icon")
    func icons() {
        #expect(AppAppearance.system.alternateIconName == nil)
        #expect(AppAppearance.light.alternateIconName == "AppIcon-Light")
        #expect(AppAppearance.dark.alternateIconName == "AppIcon-Dark")
    }

    @Test("Stored by name, System when unset")
    func stored() {
        let defaults = UserDefaults(suiteName: "appearance-\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.appearance == .system)
        preferences.appearance = .dark
        #expect(defaults.string(forKey: AppAppearance.storageKey) == "dark")
        #expect(preferences.appearance == .dark)
    }

    #if DEBUG
    @Test("A debug route starts on System, so a flip route doesn't leave its theme behind")
    func debugRouteResetsAppearance() {
        let defaults = UserDefaults(suiteName: "appearance-\(UUID().uuidString)")!
        AppPreferences(defaults: defaults).appearance = .dark
        DebugRoute.resetLaunchState(defaults)
        #expect(AppPreferences(defaults: defaults).appearance == .system)
    }
    #endif
}
