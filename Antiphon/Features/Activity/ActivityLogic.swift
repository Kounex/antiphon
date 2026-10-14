import Foundation

// MARK: - Values

/// One write a run made, as Activity shows it.
struct RunChange: Hashable, Sendable {
    let kind: ChangeKind
    /// Where the write landed.
    let platform: Platform
    let title: String
    let artist: String
    let artworkURL: URL?
    let confidence: Int?
    let reason: MatchReason?
}

/// One sync run of one seam.
struct RunRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let seamId: UUID
    let seamName: String
    let direction: SyncDirection
    let date: Date
    let trigger: SyncTrigger
    let result: SyncResultStatus?
    let duration: TimeInterval?
    let failed: Int
    let undoneAt: Date?
    let undoOfRunId: UUID?
    let changes: [RunChange]
    /// Runs logged before changes were recorded only have a count.
    var legacyAdded: Int = 0

    var hasChanges: Bool { !changes.isEmpty || failed > 0 || legacyAdded > 0 || result == .failed }

    /// Undo reverts what a run wrote; an undo itself isn't undone again.
    var canUndo: Bool { undoneAt == nil && trigger != .undo && !changes.isEmpty }

    func count(_ kind: ChangeKind, on platform: Platform) -> Int {
        changes.filter { $0.kind == kind && $0.platform == platform }.count
    }
}

/// A track monitoring brought in, not yet marked seen.
struct NewTrack: Identifiable, Hashable, Sendable {
    let id: UUID
    let seamId: UUID
    let seamName: String
    let direction: SyncDirection
    let title: String
    let artist: String
    let artworkURL: URL?
    /// Where Antiphon wrote it; it came from the other side.
    let landedOn: Platform
    let date: Date
}

// MARK: - History

enum HistoryEntry: Identifiable, Hashable, Sendable {
    case run(RunRecord)
    /// Checks of one seam in a row that changed nothing.
    case quiet(QuietChecks)

    var id: String {
        switch self {
        case .run(let run): run.id.uuidString
        case .quiet(let quiet): "quiet-\(quiet.runIds.first?.uuidString ?? "")"
        }
    }
}

struct QuietChecks: Hashable, Sendable {
    let seamId: UUID
    let seamName: String
    let latest: Date
    let runIds: [UUID]
    var count: Int { runIds.count }
}

struct ActivitySection: Identifiable, Hashable, Sendable {
    let title: String
    let entries: [HistoryEntry]
    var id: String { title }
}

enum ActivityHistory {
    /// Newest first, one section per day. Consecutive checks of the same
    /// seam that changed nothing collapse into one line.
    static func sections(_ runs: [RunRecord], now: Date, calendar: Calendar = .current) -> [ActivitySection] {
        let sorted = runs.sorted { $0.date > $1.date }
        var sections: [ActivitySection] = []
        var currentDay: Date?
        var entries: [HistoryEntry] = []

        func flush() {
            guard let day = currentDay, !entries.isEmpty else { return }
            sections.append(ActivitySection(title: title(for: day, now: now, calendar: calendar), entries: entries))
            entries = []
        }

        for run in sorted {
            let day = calendar.startOfDay(for: run.date)
            if day != currentDay {
                flush()
                currentDay = day
            }
            guard !run.hasChanges else {
                entries.append(.run(run))
                continue
            }
            if case .quiet(let quiet) = entries.last, quiet.seamId == run.seamId {
                entries[entries.count - 1] = .quiet(QuietChecks(seamId: quiet.seamId, seamName: quiet.seamName,
                                                                latest: quiet.latest, runIds: quiet.runIds + [run.id]))
            } else {
                entries.append(.quiet(QuietChecks(seamId: run.seamId, seamName: run.seamName, latest: run.date, runIds: [run.id])))
            }
        }
        flush()
        return sections
    }

    /// "Today", "Yesterday", a weekday within the week, then a date.
    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : "MMMd")
        return formatter.string(from: day)
    }
}

// MARK: - Week chart

struct WeekChart: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let label: String
        /// Tracks added or removed that day.
        let synced: Int
        /// Runs that failed that day.
        let failed: Int
        let isToday: Bool
    }

    let days: [Day]
    var total: Int { days.reduce(0) { $0 + $1.synced } }
    var failed: Int { days.reduce(0) { $0 + $1.failed } }

    /// The calendar week around `now`.
    static func make(_ runs: [RunRecord], now: Date, calendar: Calendar = .current) -> WeekChart {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return WeekChart(days: []) }
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let days = (0..<7).compactMap { offset -> Day? in
            guard let start = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let inDay = runs.filter { calendar.isDate($0.date, inSameDayAs: start) }
            let weekday = calendar.component(.weekday, from: start)
            return Day(label: String(symbols[weekday - 1].prefix(2)),
                       synced: inDay.reduce(0) { $0 + $1.changes.count },
                       failed: inDay.filter { $0.result == .failed }.count,
                       isToday: calendar.isDate(start, inSameDayAs: now))
        }
        return WeekChart(days: days)
    }
}

// MARK: - New tracks

struct NewTrackGroup: Identifiable, Hashable, Sendable {
    let seamId: UUID
    let seamName: String
    let directionText: String
    let tracks: [NewTrack]
    var id: UUID { seamId }
}

enum NewTracksGrouping {
    /// One group per seam, the seam with the newest arrival first.
    static func groups(_ tracks: [NewTrack]) -> [NewTrackGroup] {
        let bySeam = Dictionary(grouping: tracks, by: \.seamId)
        return bySeam.values.compactMap { seamTracks -> NewTrackGroup? in
            let sorted = seamTracks.sorted { $0.date > $1.date }
            guard let first = sorted.first else { return nil }
            return NewTrackGroup(seamId: first.seamId, seamName: first.seamName,
                                 directionText: first.direction == .bidirectional ? "both ways" : "one way", tracks: sorted)
        }
        .sorted { ($0.tracks.first?.date ?? .distantPast) > ($1.tracks.first?.date ?? .distantPast) }
    }
}

// MARK: - Copy

enum ActivityCopy {
    static func line(_ run: RunRecord) -> String {
        var parts: [String] = []
        for platform in [Platform.appleMusic, .spotify] {
            let added = run.count(.add, on: platform)
            if added > 0 { parts.append("\(added) added to \(platform.rawValue)") }
        }
        for platform in [Platform.spotify, .appleMusic] {
            let removed = run.count(.remove, on: platform)
            if removed > 0 { parts.append("\(removed) removed from \(platform.rawValue)") }
        }
        let moved = run.changes.filter { $0.kind == .move }.count
        if moved > 0 { parts.append("\(moved) moved") }
        if run.failed > 0 { parts.append("\(run.failed) failed") }
        if parts.isEmpty, run.legacyAdded > 0 { parts.append("\(run.legacyAdded) added") }
        if parts.isEmpty, run.result == .failed { parts.append("Sync failed") }
        var what = parts.isEmpty ? "Nothing changed" : parts.joined(separator: ", ")

        switch run.trigger {
        case .firstSync: what = "First sync · \(what)"
        case .undo: what = "Undo · \(what)"
        case .pick: what = "Your pick · \(what)"
        default: break
        }
        if run.undoneAt != nil { return "\(what) · undone" }
        if run.trigger == .monitor { return "\(what) · watching" }
        if run.direction == .bidirectional, ![.firstSync, .undo, .pick].contains(run.trigger) { return "\(what) · both ways" }
        return what
    }

    static func quietLine(_ quiet: QuietChecks) -> String {
        quiet.count == 1 ? "Checked · nothing to change" : "Checked \(quiet.count) times · nothing to change"
    }

    static func weekLine(_ week: WeekChart) -> String {
        "\(PlanCopy.count(week.total, "track")) synced this week"
    }

    static func origin(_ track: NewTrack, now: Date) -> String {
        "Added on \(track.landedOn.other.rawValue) · \(age(of: track.date, now: now))"
    }

    /// "2 h", "35 min", "3 d".
    static func age(of date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(max(1, minutes)) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / (24 * 60)) d"
    }

    static func since(_ oldest: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let oldest else { return "Tracks Antiphon adds on its own show up here." }
        let day = calendar.startOfDay(for: oldest)
        let title = ActivityHistory.title(for: day, now: now, calendar: calendar)
        return "Tracks Antiphon added on its own since \(title == "Today" || title == "Yesterday" ? title.lowercased() : title)."
    }

    static func started(_ run: RunRecord) -> String {
        let how = switch run.trigger {
        case .firstSync: "First sync"
        case .manual: "Started by you"
        case .monitor: "Started by monitoring"
        case .shortcut: "Started from Shortcuts"
        case .widget: "Started from the widget"
        case .review: "From your review"
        case .conflict: "From your answer to a removal"
        case .undo: "Undo of an earlier sync"
        case .pick: "Your pick"
        }
        guard let duration = run.duration else { return how }
        let seconds = Int(duration.rounded())
        let took = seconds < 60 ? PlanCopy.count(max(1, seconds), "second") : PlanCopy.count(seconds / 60, "minute")
        return "\(how) · took \(took)"
    }

    struct Count: Hashable {
        let title: String
        let value: String
    }

    /// "Added to Apple Music +4", "Removed 0", "Moved 1".
    static func counts(_ run: RunRecord) -> [Count] {
        var counts: [Count] = []
        for platform in [Platform.appleMusic, .spotify] {
            let added = run.count(.add, on: platform)
            if added > 0 { counts.append(Count(title: "Added to \(platform.rawValue)", value: "+\(added)")) }
        }
        let removedTotal = run.changes.filter { $0.kind == .remove }.count
        if removedTotal == 0 {
            counts.append(Count(title: "Removed", value: "0"))
        } else {
            for platform in [Platform.spotify, .appleMusic] {
                let removed = run.count(.remove, on: platform)
                if removed > 0 { counts.append(Count(title: "Removed from \(platform.rawValue)", value: "−\(removed)")) }
            }
        }
        let moved = run.changes.filter { $0.kind == .move }.count
        if moved > 0 { counts.append(Count(title: "Moved", value: "\(moved)")) }
        return counts
    }

    /// "Kavinsky · ISRC match", "Chromatics · 97% match".
    static func evidence(_ change: RunChange) -> String {
        let why: String? = switch change.reason {
        case .isrc: "ISRC match"
        case .titleArtistDuration, .titleOnly: change.confidence.map { "\($0)% match" }
        case .versionDifference: change.confidence.map { "\($0)% match, another version" }
        case .manual: "chosen by you"
        case nil: nil
        }
        return [change.artist, why].compactMap { $0 }.joined(separator: " · ")
    }
}
