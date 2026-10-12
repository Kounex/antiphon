import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Activity")
struct ActivityTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }()
    /// Wednesday 2026-10-14, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_990_000)
    private let drive = UUID(), garden = UUID()

    private func change(_ kind: ChangeKind = .add, _ platform: Platform = .appleMusic, _ title: String = "Nightcall",
                        confidence: Int? = 100, reason: MatchReason? = .isrc) -> RunChange {
        RunChange(kind: kind, platform: platform, title: title, artist: "Kavinsky", artworkURL: nil, confidence: confidence, reason: reason)
    }

    private func run(_ seam: UUID? = nil, hoursAgo: Double, trigger: SyncTrigger = .manual, direction: SyncDirection = .spotifyToApple,
                     changes: [RunChange] = [], failed: Int = 0, result: SyncResultStatus = .success, undone: Bool = false) -> RunRecord {
        let seam = seam ?? drive
        return RunRecord(id: UUID(), seamId: seam, seamName: seam == drive ? "Late Night Drive" : "Garden Sundays", direction: direction,
                         date: now.addingTimeInterval(-hoursAgo * 3600), trigger: trigger, result: result, duration: 6,
                         failed: failed, undoneAt: undone ? now : nil, undoOfRunId: nil, changes: changes)
    }

    // MARK: - One line per run

    @Test("Each run says what it changed and how it started")
    func lines() {
        #expect(ActivityCopy.line(run(hoursAgo: 1, trigger: .monitor, changes: Array(repeating: change(), count: 4)))
                == "4 added to Apple Music · watching")
        #expect(ActivityCopy.line(run(garden, hoursAgo: 4, direction: .bidirectional, changes: [change(.add, .spotify), change(.add, .spotify)]))
                == "2 added to Spotify · both ways")
        #expect(ActivityCopy.line(run(hoursAgo: 6, trigger: .firstSync, changes: Array(repeating: change(), count: 35), failed: 1))
                == "First sync · 35 added to Apple Music, 1 failed")
        #expect(ActivityCopy.line(run(hoursAgo: 1, changes: [change(.remove, .spotify)])) == "1 removed from Spotify")
        #expect(ActivityCopy.line(run(hoursAgo: 1, changes: [change()], undone: true)) == "1 added to Apple Music · undone")
        #expect(ActivityCopy.line(run(hoursAgo: 1, trigger: .undo, changes: [change(.remove)])) == "Undo · 1 removed from Apple Music")
    }

    @Test("Runs from before the redesign show their counts; failures never collapse")
    func legacyAndFailed() {
        var legacy = run(hoursAgo: 1)
        legacy.legacyAdded = 12
        #expect(legacy.hasChanges && !legacy.canUndo)
        #expect(ActivityCopy.line(legacy) == "12 added")
        let failed = run(hoursAgo: 2, result: .failed)
        #expect(failed.hasChanges)
        #expect(ActivityCopy.line(failed) == "Sync failed")
    }

    // MARK: - History

    @Test("Days are sections; quiet checks of one seam collapse into one line")
    func history() {
        let runs = [
            run(hoursAgo: 1, trigger: .monitor, changes: [change()]),
            run(hoursAgo: 2, trigger: .monitor), run(hoursAgo: 3, trigger: .monitor), run(hoursAgo: 4, trigger: .monitor),
            run(garden, hoursAgo: 5, direction: .bidirectional),
            run(hoursAgo: 30, changes: [change()])
        ]
        let sections = ActivityHistory.sections(runs, now: now, calendar: Self.calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        let today = sections[0].entries
        #expect(today.count == 3)
        if case .quiet(let quiet) = today[1] {
            #expect(quiet.count == 3)
            #expect(ActivityCopy.quietLine(quiet) == "Checked 3 times · nothing to change")
        } else {
            Issue.record("expected the three quiet checks to collapse")
        }
        if case .quiet(let single) = today[2] {
            #expect(ActivityCopy.quietLine(single) == "Checked · nothing to change")
        }
    }

    @Test("Older days are named, then dated")
    func sectionTitles() {
        let titles = ActivityHistory.sections([run(hoursAgo: 60, changes: [change()]), run(hoursAgo: 24 * 9, changes: [change()])],
                                              now: now, calendar: Self.calendar).map(\.title)
        #expect(titles == ["Monday", "Oct 5"])
    }

    // MARK: - Week chart

    @Test("This week: tracks per day and failed runs")
    func week() {
        let runs = [
            run(hoursAgo: 1, changes: Array(repeating: change(), count: 4)),
            run(hoursAgo: 26, changes: Array(repeating: change(), count: 2)),
            run(hoursAgo: 27, result: .failed),
            run(hoursAgo: 24 * 8, changes: [change()])
        ]
        let week = WeekChart.make(runs, now: now, calendar: Self.calendar)
        #expect(week.days.map(\.label) == ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"])
        #expect(week.days.map(\.synced) == [0, 0, 2, 4, 0, 0, 0])
        #expect(week.days.map(\.failed) == [0, 0, 1, 0, 0, 0, 0])
        #expect(week.days[3].isToday)
        #expect(week.total == 6 && week.failed == 1)
        #expect(ActivityCopy.weekLine(week) == "6 tracks synced this week")
    }

    // MARK: - New tracks

    @Test("New tracks are grouped by seam, newest first, with where they came from")
    func newTracks() {
        func new(_ title: String, _ seam: UUID, landedOn: Platform, hoursAgo: Double) -> NewTrack {
            NewTrack(id: UUID(), seamId: seam, seamName: seam == drive ? "Late Night Drive" : "Garden Sundays",
                     direction: seam == drive ? .spotifyToApple : .bidirectional, title: title, artist: "A", artworkURL: nil,
                     landedOn: landedOn, date: now.addingTimeInterval(-hoursAgo * 3600))
        }
        let groups = NewTracksGrouping.groups([
            new("Nightcall", drive, landedOn: .appleMusic, hoursAgo: 5),
            new("Towers", garden, landedOn: .spotify, hoursAgo: 2),
            new("A Real Hero", drive, landedOn: .appleMusic, hoursAgo: 5.1)
        ])
        #expect(groups.map(\.seamName) == ["Garden Sundays", "Late Night Drive"])
        #expect(groups[0].directionText == "both ways" && groups[1].directionText == "one way")
        #expect(groups[1].tracks.map(\.title) == ["Nightcall", "A Real Hero"])
        #expect(ActivityCopy.origin(groups[0].tracks[0], now: now) == "Added on Apple Music · 2 h")
        #expect(ActivityCopy.since(groups.flatMap(\.tracks).map(\.date).min(), now: now, calendar: Self.calendar)
                == "Tracks Antiphon added on its own since today.")
    }

    // MARK: - One run in detail

    @Test("A run's header, counts and per-track evidence")
    func detail() {
        let record = run(hoursAgo: 1, trigger: .monitor, changes: [
            change(), change(.add, .appleMusic, "Tick of the Clock", confidence: 97, reason: .titleArtistDuration),
            change(.add, .appleMusic, "Midnight City", confidence: 84, reason: .versionDifference),
            change(.add, .appleMusic, "Picked", confidence: nil, reason: .manual)
        ])
        #expect(ActivityCopy.started(record) == "Started by monitoring · took 6 seconds")
        #expect(ActivityCopy.counts(record).map { "\($0.title) \($0.value)" } == ["Added to Apple Music +4", "Removed 0"])
        #expect(record.changes.map(ActivityCopy.evidence) == ["Kavinsky · ISRC match", "Kavinsky · 97% match",
                                                              "Kavinsky · 84% match, another version", "Kavinsky · chosen by you"])
        #expect(record.canUndo)
        #expect(!run(hoursAgo: 1, changes: [change()], undone: true).canUndo)
        #expect(!run(hoursAgo: 1, trigger: .undo, changes: [change(.remove)]).canUndo)
        #expect(!run(hoursAgo: 1).canUndo)
    }
}

@Suite("Activity store", .serialized)
@MainActor
struct ActivityRepositoryTests {
    private func seed() throws -> (ModelContainer, UUID) {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: "Late Night Drive",
                            appleMusicPlaylistId: "am", appleMusicPlaylistName: "Late Night Drive", syncDirection: .spotifyToApple)
        context.insert(pair)
        func log(_ trigger: SyncTrigger, minutesAgo: Double, adds: [String]) -> SyncLog {
            let log = SyncLog(action: trigger == .monitor ? .monitorSync : .manualSync, tracksAdded: adds.count)
            log.syncPair = pair
            log.trigger = trigger
            log.timestamp = Date().addingTimeInterval(-minutesAgo * 60)
            log.startedAt = log.timestamp
            context.insert(log)
            for (n, title) in adds.enumerated() {
                let change = SyncChange(platform: .appleMusic, kind: .add,
                                        track: CatalogTrack(platform: .appleMusic, id: "am-\(title)", title: title, artist: "A"),
                                        confidence: 100, reason: .isrc)
                change.sequence = n
                change.run = log
                context.insert(change)
            }
            return log
        }
        let watched = log(.monitor, minutesAgo: 30, adds: ["Nightcall", "A Real Hero"])
        _ = log(.widget, minutesAgo: 45, adds: ["Outrun"])
        _ = log(.manual, minutesAgo: 60, adds: ["Tick of the Clock"])
        try context.save()
        return (container, watched.id)
    }

    @Test("Runs come with their seam, trigger and changes in order")
    func runs() async throws {
        let (container, watchedId) = try seed()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let runs = try await repository.runs()
        #expect(runs.count == 3)
        #expect(runs.first?.id == watchedId)
        #expect(runs.first?.seamName == "Late Night Drive")
        #expect(runs.first?.trigger == .monitor)
        #expect(runs.first?.changes.map(\.title) == ["Nightcall", "A Real Hero"])
        #expect(try await repository.run(watchedId)?.changes.count == 2)
    }

    @Test("New tracks are what Antiphon added on its own (background runs, Sync all, Shortcuts) until marked seen")
    func newTracks() async throws {
        let (container, _) = try seed()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let fresh = try await repository.newTracks()
        #expect(Set(fresh.map(\.title)) == ["Nightcall", "A Real Hero", "Outrun"])
        #expect(fresh.allSatisfy { $0.landedOn == .appleMusic })
        try await repository.markAllSeen()
        #expect(try await repository.newTracks().isEmpty)
    }
}
