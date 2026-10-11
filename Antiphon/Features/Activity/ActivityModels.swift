import Foundation
import Observation

/// Activity: every sync as a log entry, and the tracks monitoring brought in.
@MainActor
@Observable
final class ActivityModel {
    enum Tab: Hashable { case history, newTracks }

    var tab: Tab = .history
    private(set) var runs: [RunRecord] = []
    private(set) var newTracks: [NewTrack] = []
    private(set) var isLoading = true
    private(set) var loadError: String?

    private let activity: ActivityRepository
    private let now: () -> Date

    init(activity: ActivityRepository, now: @escaping () -> Date = Date.init) {
        self.activity = activity
        self.now = now
    }

    func load() async {
        defer { isLoading = false }
        do {
            async let runs = activity.runs()
            async let fresh = activity.newTracks()
            (self.runs, self.newTracks) = try await (runs, fresh)
            loadError = nil
        } catch {
            loadError = "Antiphon couldn't read its history."
        }
    }

    var sections: [ActivitySection] { ActivityHistory.sections(runs, now: now()) }
    var week: WeekChart { WeekChart.make(runs, now: now()) }
    var groups: [NewTrackGroup] { NewTracksGrouping.groups(newTracks) }
    var sinceText: String { ActivityCopy.since(newTracks.map(\.date).min(), now: now()) }
    var currentDate: Date { now() }

    func markAllSeen() async {
        try? await activity.markAllSeen()
        newTracks = []
    }
}

/// One sync in detail, with undo.
@MainActor
@Observable
final class RunDetailModel {
    let runId: UUID
    private(set) var record: RunRecord?
    private(set) var undoPlan: UndoPlan?
    private(set) var isUndoing = false
    /// What happened after undo, or why it couldn't.
    private(set) var message: String?
    private(set) var messageIsError = false

    private let activity: ActivityRepository
    private let sync: SyncService

    init(runId: UUID, activity: ActivityRepository, sync: SyncService) {
        self.runId = runId
        self.activity = activity
        self.sync = sync
    }

    func load() async {
        record = try? await activity.run(runId)
        guard let record, record.canUndo else { undoPlan = nil; return }
        undoPlan = try? await sync.undoPreview(runId: runId)
    }

    /// Says exactly what reverting touches, before anything is touched.
    var undoExplanation: String? {
        guard let undoPlan else { return nil }
        return [undoPlan.summary, undoPlan.guidedNote].compactMap { $0 }.joined(separator: " ")
    }

    var canUndo: Bool {
        guard let record, let undoPlan else { return false }
        return record.canUndo && !(undoPlan.operations.isEmpty && undoPlan.guided.isEmpty)
    }

    func undo() async {
        guard canUndo, !isUndoing else { return }
        isUndoing = true
        defer { isUndoing = false }
        do {
            let outcome = try await sync.undo(runId: runId)
            message = RunDetailCopy.undone(outcome)
            messageIsError = false
        } catch {
            message = "Antiphon couldn't undo this sync. Nothing was changed. Try again in a moment."
            messageIsError = true
        }
        await load()
    }
}

enum RunDetailCopy {
    static func undone(_ outcome: OperationRunner.Outcome) -> String {
        var parts: [String] = []
        let landed = outcome.landed.count
        parts.append(landed == 0 ? "Nothing needed undoing." : "Undone: \(PlanCopy.count(landed, "change")) reverted.")
        if !outcome.skipped.isEmpty {
            parts.append("\(PlanCopy.count(outcome.skipped.count, "track")) had already changed by hand and were left alone.")
        }
        if !outcome.guided.isEmpty {
            parts.append("Remove \(PlanCopy.count(outcome.guided.count, "track")) yourself in the Music app: \(outcome.guided.map(\.track.title).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
