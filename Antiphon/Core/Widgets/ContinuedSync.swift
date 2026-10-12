import BackgroundTasks
import Foundation
import Synchronization
import UIKit

/// What iOS shows for a sync that keeps running after the person leaves the app.
enum ContinuedSyncCopy {
    static func identifier(bundleID: String, run: UUID) -> String {
        "\(bundleID).sync.\(run.uuidString)"
    }

    static func title(seamName: String) -> String { "Syncing \(seamName)" }

    static func subtitle(_ state: SyncActivityAttributes.ContentState) -> String {
        var parts = [state.phase]
        if state.total > 0 { parts.append("\(state.done) of \(state.total)") }
        // iOS shows one line beside its progress ring: no room for time left.
        return parts.joined(separator: " · ")
    }

    /// Thousandths of the whole sync, for the task's `Progress`: checking the
    /// tracks is the first 30%, adding them the next 69%, and 100% is set only
    /// when the sync ends. Progress that finished and restarted per phase
    /// could read to iOS as a task that was done.
    static func completedUnits(_ state: SyncActivityAttributes.ContentState) -> Int64 {
        let fraction = state.total > 0 ? min(1, Double(state.done) / Double(state.total)) : 0
        let units = state.phase.hasPrefix("Adding") ? 300 + 690 * fraction : 300 * fraction
        return Int64(units.rounded(.down))
    }
}

/// Keeps a sync the person started in the app running after they leave it
/// (iOS 26 `BGContinuedProcessingTask`). iOS shows its own progress for it,
/// filled from the sync's progress. If iOS declines, the sync gets the usual
/// few seconds of background time and the Live Activity says when it pauses.
@MainActor
final class ContinuedSync {
    private var task: BGContinuedProcessingTask?
    private var pending: SyncActivityAttributes.ContentState?
    private let title: String
    /// The task is reported done once: by the sync, or by expiry on iOS's queue.
    private let completion = CompletionFlag()

    private init(title: String) {
        self.title = title
    }

    /// Asks iOS to let the sync continue in the background. Must be called
    /// while the app is on screen, right after the person started the sync.
    /// `onExpire` stops the sync when iOS or the person ends the task.
    static func start(seamName: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> ContinuedSync? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let identifier = ContinuedSyncCopy.identifier(bundleID: bundleID, run: UUID())
        let continued = ContinuedSync(title: ContinuedSyncCopy.title(seamName: seamName))
        // Continued-processing handlers may be registered at any time, once per
        // identifier. Delivered on the main queue: this closure is main-actor
        // code (Swift checks that at run time; another queue crashes the app).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                // iOS calls this on its own queue: not main-actor code. It must
                // report the task done right away or iOS terminates the app;
                // then the sync is cancelled, which puts unwritten tracks back
                // to pending.
                nonisolated(unsafe) let expiring = task
                let completion = continued.completion
                task.expirationHandler = { @Sendable in
                    #if DEBUG
                    SyncDiagnostics.log("expired by iOS")
                    #endif
                    if completion.claim() { expiring.setTaskCompleted(success: false) }
                    Task { @MainActor in onExpire() }
                }
                continued.attach(task)
            }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: continued.title, subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            SyncDiagnostics.log("submitted \(identifier)")
            continued.watchProtectedData()
            #endif
            return continued
        } catch {
            print("[ContinuedSync] Not granted: \(error.localizedDescription)")
            #if DEBUG
            SyncDiagnostics.log("not granted: \(error)")
            #endif
            return nil
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        // The sync already ended before iOS handed over the task: close it now.
        if let finishedWith {
            if completion.claim() { task.setTaskCompleted(success: finishedWith) }
            return
        }
        self.task = task
        #if DEBUG
        SyncDiagnostics.log("granted")
        #endif
        task.progress.totalUnitCount = 1000
        if let pending { show(pending) }
    }

    /// Keeps iOS's progress up to date; a task that looks stalled is ended by iOS.
    func show(_ state: SyncActivityAttributes.ContentState) {
        defer { pending = state }
        guard let task else { return }
        #if DEBUG
        if state.done != pending?.done || state.phase != lastLoggedPhase {
            lastLoggedPhase = state.phase
            SyncDiagnostics.log("progress \(state.phase) \(state.done)/\(state.total) locked: \(!UIApplication.shared.isProtectedDataAvailable) app: \(UIApplication.shared.applicationState.rawValue)")
        }
        #endif
        // Never backwards.
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, ContinuedSyncCopy.completedUnits(state))
        task.updateTitle(title, subtitle: ContinuedSyncCopy.subtitle(state))
    }

    #if DEBUG
    private var lastLoggedPhase: String?
    private var observers: [NSObjectProtocol] = []

    fileprivate func watchProtectedData() {
        for (name, label) in [(UIApplication.protectedDataWillBecomeUnavailableNotification, "locked (Music library unavailable)"),
                              (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                SyncDiagnostics.log(label)
            })
        }
    }
    #endif

    private var finishedWith: Bool?

    func finish(success: Bool) {
        finishedWith = success
        #if DEBUG
        SyncDiagnostics.log("finished, success: \(success)")
        observers.forEach(NotificationCenter.default.removeObserver)
        #endif
        if let task, completion.claim() {
            task.progress.completedUnitCount = 1000
            task.setTaskCompleted(success: success)
        }
        task = nil
    }
}

/// True the first time it's claimed, from any thread.
private final class CompletionFlag: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
