import Foundation
@preconcurrency import BackgroundTasks
import Network
import os
import SwiftData
import UserNotifications

/// Manages background task registration and scheduling for playlist sync.
///
/// Creates its own `SpotifyAPIClient` and `AppleMusicManager` per background
/// execution, isolating background work from the foreground UI's shared instances.
/// This follows the same self-contained pattern as `SyncPlaylistsIntent`.
enum BackgroundTaskManager {

    /// Registers the background refresh task handler.
    /// Must be called before the app finishes launching.
    static func registerTasks(modelContainer: ModelContainer) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConstants.BackgroundTasks.playlistRefreshIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleAppRefresh(task: refreshTask, modelContainer: modelContainer)
        }
        print("[BackgroundTaskManager] Registered background refresh handler")
    }

    /// Asks iOS for the next run when the soonest monitored seam is due.
    /// Should be called when the app enters the background.
    static func scheduleBackgroundRefresh(modelContainer: ModelContainer = SharedModelContainer.container) {
        let preferences = AppPreferences.shared
        let seams = monitoredSeams(in: modelContainer)
        guard let begin = MonitorSchedule.nextBegin(seams, defaultMinutes: preferences.monitorIntervalMinutes, now: Date()) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppConstants.BackgroundTasks.playlistRefreshIdentifier)
            print("[BackgroundTaskManager] Nothing monitored; no refresh scheduled")
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.BackgroundTasks.playlistRefreshIdentifier)
        request.earliestBeginDate = begin
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundTaskManager] Next refresh no earlier than \(begin)")
        } catch {
            print("[BackgroundTaskManager] Failed to schedule background refresh: \(error)")
        }
    }

    // MARK: - Private

    static func monitoredSeams(in container: ModelContainer) -> [MonitorSchedule.Seam] {
        let context = ModelContext(container)
        let pairs = (try? context.fetch(FetchDescriptor<SyncPair>(
            predicate: #Predicate { $0.isMonitored == true && $0.pausedAt == nil }
        ))) ?? []
        return pairs.map { MonitorSchedule.Seam(id: $0.id, intervalMinutes: $0.monitorIntervalMinutes, lastSyncedAt: $0.lastSyncedAt) }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask, modelContainer: ModelContainer) {
        print("[BackgroundTaskManager] Background refresh triggered")
        let expired = OSAllocatedUnfairLock(initialState: false)

        let syncTask = Task { @Sendable in
            defer { scheduleBackgroundRefresh(modelContainer: modelContainer) }
            let report = await MonitorRun.perform(modelContainer: modelContainer, isExpired: { expired.withLock { $0 } })
            print("[BackgroundTaskManager] Background run: \(report.summary)")
            task.setTaskCompleted(success: report.succeeded)
        }

        task.expirationHandler = {
            print("[BackgroundTaskManager] Background task expired, cancelling sync")
            expired.withLock { $0 = true }
            syncTask.cancel()
        }
    }
}

/// What a background run did, per seam, and what to say about it.
enum MonitorRun {
    struct Report: Sendable {
        var blocker: MonitorGates.Blocker?
        var due: [UUID] = []
        var results: [SyncResult] = []
        var messages: [MonitorNotifications.Message] = []
        var expired = false

        var succeeded: Bool { !expired && results.allSatisfy { $0.status != .failed } }
        var summary: String {
            if let blocker { return "skipped (\(blocker))" }
            return "\(due.count) due, \(results.filter(\.isSuccess).count) synced, \(messages.count) notifications"
        }
    }

    /// One background run: checks the gates, syncs the seams that are due
    /// and tells the person what they asked to hear about.
    static func perform(modelContainer: ModelContainer, preferences: AppPreferences = .shared, now: Date = Date(),
                        onWiFi: Bool? = nil, lowPower: Bool? = nil, post: Bool = true,
                        isExpired: @Sendable () -> Bool = { false }) async -> Report {
        var report = Report()
        let wifi: Bool
        if let onWiFi { wifi = onWiFi } else { wifi = await NetworkCheck.isOnWiFi() }
        if let blocker = MonitorGates.blocker(preferences.monitorGates, onWiFi: wifi,
                                              lowPower: lowPower ?? ProcessInfo.processInfo.isLowPowerModeEnabled, now: now) {
            report.blocker = blocker
            return report
        }
        report.due = MonitorSchedule.due(BackgroundTaskManager.monitoredSeams(in: modelContainer),
                                         defaultMinutes: preferences.monitorIntervalMinutes, now: now)
        guard !report.due.isEmpty else { return report }

        let repository = SwiftDataSeamRepository(modelContainer: modelContainer)
        let before = (try? await repository.seams()) ?? []
        let engine = SyncEngine(modelContainer: modelContainer, spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        report.results = await engine.syncAllMonitored(only: Set(report.due), preferences: preferences)
        let after = (try? await repository.seams()) ?? []

        report.expired = isExpired()
        guard !report.expired else { return report }
        let outcomes = outcomes(before: before, after: after, results: report.results)
        report.messages = MonitorNotifications.messages(outcomes, preferences.notificationPreferences)
        if post { await notify(report.messages, repository: repository, preferences: preferences) }
        // Notifications first: the widgets can wait, a question can't.
        if !isExpired() { await WidgetSnapshotWriter.refresh(modelContainer: modelContainer) }
        return report
    }

    static func outcomes(before: [SeamSummary], after: [SeamSummary], results: [SyncResult]) -> [MonitorNotifications.SeamOutcome] {
        let beforeById = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let afterById = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return results.compactMap { result in
            guard let seam = afterById[result.pairId] ?? beforeById[result.pairId] else { return nil }
            let questionsBefore = beforeById[result.pairId]?.counts.review ?? 0
            let questionsAfter = afterById[result.pairId]?.counts.review ?? questionsBefore
            return MonitorNotifications.SeamOutcome(
                seamId: seam.id, seamName: seam.name, added: result.tracksAdded,
                newQuestions: max(0, questionsAfter - questionsBefore),
                failure: result.status == .failed ? (result.message ?? "Open Antiphon to see what went wrong.") : nil
            )
        }
    }

    /// Posts what the person asked to hear about, and refreshes the
    /// pending daily summary and weekly digest with today's numbers.
    static func notify(_ messages: [MonitorNotifications.Message], repository: SwiftDataSeamRepository,
                       preferences: AppPreferences) async {
        let center = UNUserNotificationCenter.current()
        for message in messages {
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = message.kind == .newTracks ? nil : .default
            content.threadIdentifier = message.kind.rawValue
            try? await center.add(UNNotificationRequest(identifier: "\(message.kind.rawValue)-\(UUID().uuidString)", content: content, trigger: nil))
        }
        await NotificationScheduler.refreshScheduled(repository: repository, preferences: preferences)
    }
}

/// The daily summary and weekly digest are scheduled notifications, rewritten
/// by each background run with the numbers so far. iOS may not run Antiphon
/// late in the day, so a summary can miss the last few tracks.
enum NotificationScheduler {
    static let summaryId = "daily-summary"
    static let digestId = "weekly-digest"
    static let summaryHour = 19
    static let digestWeekday = 1  // Sunday
    static let digestHour = 10

    static func refreshScheduled(repository: SwiftDataSeamRepository, preferences: AppPreferences, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let runs = (try? await repository.runs()) ?? []
        let calendar = Calendar.current

        center.removePendingNotificationRequests(withIdentifiers: [summaryId])
        if preferences.notifyNewTracks == .dailySummary {
            let today = runs.filter { $0.trigger == .monitor && calendar.isDate($0.date, inSameDayAs: now) && $0.undoneAt == nil }
            let tracks = today.reduce(0) { $0 + $1.count(.add, on: .spotify) + $1.count(.add, on: .appleMusic) }
            let seams = Set(today.filter { !$0.changes.isEmpty }.map(\.seamId)).count
            if let body = MonitorNotifications.dailySummary(tracks: tracks, seams: seams),
               calendar.component(.hour, from: now) < summaryHour {
                await schedule(id: summaryId, title: "Today in Antiphon", body: body,
                               components: DateComponents(hour: summaryHour), repeats: false)
            }
        }

        center.removePendingNotificationRequests(withIdentifiers: [digestId])
        if preferences.weeklyDigest {
            let week = runs.filter { now.timeIntervalSince($0.date) < 7 * 86_400 }
            let tracks = week.reduce(0) { $0 + $1.changes.count }
            let seams = Set(week.filter { !$0.changes.isEmpty }.map(\.seamId)).count
            let failed = week.filter { $0.result == .failed }.count
            await schedule(id: digestId, title: "Your week in Antiphon",
                           body: MonitorNotifications.weeklyDigest(tracks: tracks, seams: seams, failed: failed),
                           components: DateComponents(hour: digestHour, weekday: digestWeekday), repeats: false)
        }
    }

    private static func schedule(id: String, title: String, body: String, components: DateComponents, repeats: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = id
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Whether the device is on Wi-Fi right now, read once.
enum NetworkCheck {
    static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: DispatchQueue(label: "antiphon.network-check"))
        }
    }
}
