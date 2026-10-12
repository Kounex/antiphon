import ActivityKit
import Foundation

/// What the Live Activity says, from the sync's own progress.
enum SyncActivityContent {
    typealias State = SyncActivityAttributes.ContentState

    static func state(seamName: String, progress: SyncProgress) -> State {
        let phase = switch progress.phase {
        case .matching: "Checking tracks"
        case .adding(let platformName): "Adding to \(platformName)"
        }
        return State(seamName: seamName, phase: phase, done: progress.completedTracks + progress.failedTracks,
                     total: progress.totalTracks)
    }

    /// "about 2 min left", once enough tracks have gone through this phase
    /// to tell; `nil` before that.
    static func timeLeft(done: Int, total: Int, elapsed: TimeInterval) -> String? {
        guard done >= 5, elapsed > 0, total > done else { return nil }
        let seconds = Double(total - done) / (Double(done) / elapsed)
        if seconds < 30 { return "a few seconds left" }
        return "about \(Int((seconds / 60).rounded(.up))) min left"
    }

    static func direction(_ direction: SyncDirection) -> String {
        switch direction {
        case .spotifyToApple: "Spotify → Apple Music"
        case .appleToSpotify: "Apple Music → Spotify"
        case .bidirectional: "Spotify ↔ Apple Music"
        }
    }

    /// The big number and its caption: "20", "of 35".
    static func count(_ state: State) -> (String, String) {
        ("\(state.done)", "of \(state.total)")
    }

    static func finished(seamName: String, result: SyncResult) -> State {
        // Partial also covers a pause, a stale preview and tracks left for
        // the next run, so it says no more than that.
        let phase: String = switch result.status {
        case .failed: "Didn't finish. Open Antiphon to see why."
        case .partial: (result.tracksAdded > 0 ? "\(result.tracksAdded) added · not everything is done" : "Not everything is done")
            + ". Open Antiphon to see what's left."
        case .success, .inProgress: result.tracksAdded > 0 ? "Synced · \(result.tracksAdded) added" : "In sync"
        }
        return State(seamName: seamName, phase: phase, done: 1, total: 1, finished: true, failed: result.status == .failed)
    }

    /// The end of Sync all. `waiting`: seams it left to the person
    /// (`SyncAllScope`), said rather than skipped quietly.
    static func finishedAll(_ results: [SyncResult], waiting: Int = 0) -> State {
        let synced = results.filter { $0.status == .success }.count
        let added = results.reduce(0) { $0 + $1.tracksAdded }
        let waitingText = "\(waiting) \(results.isEmpty ? (waiting == 1 ? "seam waits" : "seams wait") : "wait") for you in Antiphon"
        guard !results.isEmpty else {
            return State(seamName: "Sync all", phase: "Nothing to sync yet · \(waitingText)", done: 1, total: 1, finished: true)
        }
        var phase = "\(synced) of \(results.count) \(results.count == 1 ? "seam" : "seams") fully synced · \(added) added"
        if waiting > 0 { phase += " · \(waitingText)" }
        if synced < results.count { phase += ". Open Antiphon to see what's left." }
        return State(seamName: "Sync all", phase: phase, done: 1, total: 1, finished: true,
                     failed: !results.isEmpty && results.allSatisfy { $0.status == .failed })
    }
}

/// Which seams Sync all leaves to the person: a first sync and a rebuild
/// are always previewed, and paused seams stay paused.
enum SyncAllScope {
    static func waiting(_ seams: [SeamSummary]) -> Int {
        seams.filter { $0.lastCheckedAt == nil || $0.isPaused || $0.needsRebuild }.count
    }
}

/// Runs one sync's Live Activity: starts it once the sync has taken 20
/// seconds, follows its progress within ActivityKit's limits, ends it with
/// the result. Does nothing when Live Activities are off.
@MainActor
final class SyncLiveActivity {
    private let startedAt: Date
    var isActive: Bool { activity != nil }

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }
    private var activity: Activity<SyncActivityAttributes>?
    private var shown: SyncActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private var latest: SyncActivityAttributes.ContentState?
    /// iOS shows this sync's progress itself (continued processing): don't start one.
    var isSuppressed = false
    /// Every state as it's computed, before any throttling.
    var onState: ((SyncActivityAttributes.ContentState) -> Void)?
    private var phaseName: String?
    private var phaseStartedAt = Date()
    /// Cover files for the current seam, added to every state.
    private var covers: (source: String?, target: String?) = (nil, nil)
    private var coversFor: UUID?

    /// Follows `seam`'s progress; its covers are fetched once the activity
    /// is (about to be) on screen.
    func show(seam: SeamSummary?, progress: SyncProgress) async {
        if let seam, seam.id != coversFor,
           activity != nil || SyncActivityPolicy.shouldStart(startedAt: startedAt, now: Date()) {
            coversFor = seam.id
            covers = (await WidgetSnapshotWriter.cover(for: seam.side(seam.source).artworkURL),
                      await WidgetSnapshotWriter.cover(for: seam.side(seam.source.other).artworkURL))
        }
        var state = SyncActivityContent.state(seamName: seam?.name ?? "Sync", progress: progress)
        // Time left is measured within a phase (checking, then adding).
        if state.phase != phaseName { phaseName = state.phase; phaseStartedAt = Date() }
        let left = SyncActivityContent.timeLeft(done: state.done, total: state.total,
                                                elapsed: Date().timeIntervalSince(phaseStartedAt))
        state.direction = seam.map { SyncActivityContent.direction($0.direction) }
        state.timeLeft = left
        onState?(state)
        await show(state)
    }

    func show(_ state: SyncActivityAttributes.ContentState, startNow: Bool = false) async {
        var state = state
        state.sourceCover = covers.source
        state.targetCover = covers.target
        latest = state
        let now = Date()
        if let activity {
            guard let shown, SyncActivityPolicy.shouldUpdate(from: shown, to: state, lastUpdate: lastUpdate, now: now) else { return }
            // `Activity` isn't marked Sendable, but ActivityKit allows its calls from any thread.
            nonisolated(unsafe) let current = activity
            await current.update(ActivityContent(state: state, staleDate: SyncActivityPolicy.staleDate(now: now)))
        } else {
            guard !isSuppressed, startNow || SyncActivityPolicy.shouldStart(startedAt: startedAt, now: now),
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(attributes: SyncActivityAttributes(),
                                                content: ActivityContent(state: state, staleDate: SyncActivityPolicy.staleDate(now: now)))
            } catch {
                print("[LiveActivity] Not started: \(error.localizedDescription)")
                return
            }
        }
        shown = state
        lastUpdate = now
    }

    /// iOS lets an app start a Live Activity only from the foreground: when
    /// the person leaves the app mid-sync, start it now rather than at 20 s.
    func startBeforeLeaving() async {
        guard activity == nil, let latest else { return }
        await show(latest, startNow: true)
    }

    /// Activities left behind by a sync that never finished (the app was
    /// killed). Called at launch, when nothing can be running yet.
    static func endLeftovers() async {
        for leftover in Activity<SyncActivityAttributes>.activities {
            await leftover.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Shows how it ended for a few minutes, then iOS removes it.
    func finish(_ state: SyncActivityAttributes.ContentState) async {
        guard let activity else { return }
        var state = state
        state.sourceCover = covers.source
        state.targetCover = covers.target
        nonisolated(unsafe) let current = activity
        // The result first, in the Dynamic Island too; then end, which leaves
        // it on the Lock Screen for a few minutes.
        await current.update(ActivityContent(state: state, staleDate: SyncActivityPolicy.staleDate(now: Date())))
        try? await Task.sleep(for: .seconds(SyncActivityPolicy.resultShownFor))
        await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(5 * 60)))
        self.activity = nil
    }
}
