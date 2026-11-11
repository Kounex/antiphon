import Foundation

/// Which monitored seams a background run syncs, and when to ask iOS for
/// the next run. iOS decides the exact moment; this only says what's due.
enum MonitorSchedule {
    /// iOS doesn't run app refresh more often than this anyway.
    static let minimumMinutes = 15

    struct Seam: Sendable, Equatable {
        let id: UUID
        /// The seam's own interval; `nil` uses the app default.
        let intervalMinutes: Int?
        /// `nil`: never synced. A first sync is always previewed, never monitored.
        let lastSyncedAt: Date?
    }

    static func due(_ seams: [Seam], defaultMinutes: Int, now: Date) -> [UUID] {
        seams.filter { seam in
            guard let last = seam.lastSyncedAt else { return false }
            return now.timeIntervalSince(last) >= Double(interval(seam, defaultMinutes)) * 60
        }.map(\.id)
    }

    /// When the soonest seam is due, but not sooner than 15 minutes, and not
    /// inside quiet hours: a run then checks nothing, and each wasted
    /// wake-up counts against what iOS lets Antiphon do in the background.
    static func nextBegin(_ seams: [Seam], defaultMinutes: Int, now: Date,
                          quietHours: MonitorGates.QuietHours? = nil, calendar: Calendar = .current) -> Date? {
        let waits = seams.compactMap { seam -> TimeInterval? in
            guard let last = seam.lastSyncedAt else { return nil }
            return last.addingTimeInterval(Double(interval(seam, defaultMinutes)) * 60).timeIntervalSince(now)
        }
        guard let soonest = waits.min() else { return nil }
        let begin = now.addingTimeInterval(max(soonest, Double(minimumMinutes) * 60))
        guard let quietHours, quietHours.startMinute != quietHours.endMinute else { return begin }
        let parts = calendar.dateComponents([.hour, .minute], from: begin)
        guard quietHours.contains((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) else { return begin }
        let end = DateComponents(hour: quietHours.endMinute / 60, minute: quietHours.endMinute % 60, second: 0)
        return calendar.nextDate(after: begin, matching: end, matchingPolicy: .nextTime) ?? begin
    }

    private static func interval(_ seam: Seam, _ defaultMinutes: Int) -> Int {
        max(minimumMinutes, seam.intervalMinutes.flatMap { $0 > 0 ? $0 : nil } ?? defaultMinutes)
    }
}

/// Conditions under which a background run checks nothing.
enum MonitorGates {
    struct QuietHours: Codable, Equatable, Sendable {
        /// Minutes after midnight.
        var startMinute: Int
        var endMinute: Int

        func contains(_ minute: Int) -> Bool {
            startMinute <= endMinute
                ? (startMinute..<endMinute).contains(minute)
                : minute >= startMinute || minute < endMinute
        }
    }

    struct Settings: Equatable, Sendable {
        var wifiOnly: Bool
        var pauseInLowPower: Bool
        var quietHours: QuietHours?
    }

    enum Blocker: Equatable, Sendable {
        case quietHours, notOnWiFi, lowPower
    }

    static func blocker(_ settings: Settings, onWiFi: Bool, lowPower: Bool, now: Date, calendar: Calendar = .current) -> Blocker? {
        if let quiet = settings.quietHours {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            if quiet.contains((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) { return .quietHours }
        }
        if settings.wifiOnly, !onWiFi { return .notOnWiFi }
        if settings.pauseInLowPower, lowPower { return .lowPower }
        return nil
    }
}

/// What to tell the person after a background run. Split by whether they
/// need to act; routine syncs can batch into a daily summary.
enum MonitorNotifications {
    enum NewTracks: String, CaseIterable, Sendable {
        case off, eachSync, dailySummary
    }

    struct Preferences: Equatable, Sendable {
        var decide: Bool
        var breaks: Bool
        var newTracks: NewTracks
    }

    struct SeamOutcome: Equatable, Sendable {
        let seamId: UUID
        let seamName: String
        /// Tracks this run added.
        let added: Int
        /// Close matches and removals newly waiting for an answer.
        let newQuestions: Int
        /// Set when the seam's sync failed, in words.
        let failure: String?
        /// Their titles, in the order they landed. Empty if not known.
        var addedTitles: [String] = []
    }

    /// "Nightcall, A Real Hero and 2 more are new in Late Night Drive."
    /// A name says more than a count: it's the friend's song that arrived.
    static func newTracksLine(_ outcome: SeamOutcome) -> String {
        let titles = outcome.addedTitles
        switch titles.count {
        case 0: return "\(PlanCopy.count(outcome.added, "new track")) in \(outcome.seamName)."
        case 1: return "\(titles[0]) is new in \(outcome.seamName)."
        case 2: return "\(titles[0]) and \(titles[1]) are new in \(outcome.seamName)."
        default: return "\(titles[0]), \(titles[1]) and \(titles.count - 2) more are new in \(outcome.seamName)."
        }
    }

    enum Kind: String, Sendable {
        case decide, breaks, newTracks, summary, digest
    }

    struct Message: Equatable, Sendable {
        let kind: Kind
        let title: String
        let body: String
    }

    static func messages(_ outcomes: [SeamOutcome], _ prefs: Preferences) -> [Message] {
        var messages: [Message] = []
        let asking = outcomes.filter { $0.newQuestions > 0 }
        if prefs.decide, !asking.isEmpty {
            let total = asking.reduce(0) { $0 + $1.newQuestions }
            let body = asking.count == 1
                ? "\(asking[0].seamName) has \(PlanCopy.count(total, "track")) waiting for your call."
                : "\(PlanCopy.count(total, "track")) in \(asking.count) seams are waiting for your call."
            messages.append(Message(kind: .decide, title: "Your call", body: body))
        }
        let broken = outcomes.filter { $0.failure != nil }
        if prefs.breaks, !broken.isEmpty {
            let body = broken.count == 1
                ? broken[0].failure ?? ""
                : "\(broken.count) seams couldn't sync. Open Antiphon to see why."
            messages.append(Message(kind: .breaks, title: broken.count == 1 ? "\(broken[0].seamName) didn't sync" : "Syncs failed", body: body))
        }
        let adding = outcomes.filter { $0.added > 0 }
        if prefs.newTracks == .eachSync, !adding.isEmpty {
            let total = adding.reduce(0) { $0 + $1.added }
            let body = adding.count == 1
                ? newTracksLine(adding[0])
                : "\(PlanCopy.count(total, "new track")) in \(adding.count) seams."
            messages.append(Message(kind: .newTracks, title: "New tracks", body: body))
        }
        return messages
    }

    static func dailySummary(tracks: Int, seams: Int) -> String? {
        guard tracks > 0 else { return nil }
        return seams > 1
            ? "Antiphon synced \(PlanCopy.count(tracks, "new track")) across \(seams) seams today."
            : "Antiphon synced \(PlanCopy.count(tracks, "new track")) today."
    }

    static func weeklyDigest(tracks: Int, seams: Int, failed: Int) -> String {
        var text = tracks == 0 ? "No new tracks this week." : "\(PlanCopy.count(tracks, "track")) synced across \(PlanCopy.count(seams, "seam")) this week."
        if failed > 0 { text += " \(PlanCopy.count(failed, "sync")) failed." }
        return text
    }
}

/// How often tracks that weren't found are looked up again, after the
/// first few tries.
enum RecheckCadence: String, CaseIterable, Sendable {
    case daily, weekly, monthly, never

    var days: Int? {
        switch self {
        case .daily: 1
        case .weekly: 7
        case .monthly: 30
        case .never: nil
        }
    }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .never: "Never"
        }
    }
}

enum AvailabilityRecheck {
    static func isDue(retryCount: Int, lastAttempt: Date?, cadence: RecheckCadence, now: Date) -> Bool {
        if retryCount < PlanBuilder.maxRetries { return true }
        guard let days = cadence.days else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Double(days) * 86_400
    }
}

/// How often iOS really woke Antiphon in the background. The interval a
/// person picks is only a request; this is what happened.
enum MonitorCadence {
    /// Runs kept: a few weeks at the busiest.
    static let keep = 200

    static func recording(_ date: Date, in runs: [Date]) -> [Date] {
        Array((runs + [date]).suffix(keep))
    }

    /// `nil` until a background run has ever been recorded.
    static func summary(runs: [Date], now: Date) -> String? {
        guard !runs.isEmpty else { return nil }
        let recent = runs.filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 86_400 }
        guard let last = recent.max() else {
            return "iOS hasn't run Antiphon in the background in the last 24 hours. It decides by how often you open the app."
        }
        let minutes = Int(now.timeIntervalSince(last) / 60)
        let ago = minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(Int((Double(minutes) / 60).rounded())) h ago"
        return recent.count == 1
            ? "iOS ran Antiphon in the background once in the last 24 hours, \(ago)."
            : "iOS ran Antiphon in the background \(recent.count) times in the last 24 hours, last \(ago)."
    }
}
