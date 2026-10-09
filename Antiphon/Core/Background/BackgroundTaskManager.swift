import Foundation
@preconcurrency import BackgroundTasks
import os
import SwiftData

/// Manages background task registration and scheduling for playlist sync.
///
/// Creates its own `SpotifyAuthManager` and `AppleMusicManager` per background
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
            handleAppRefresh(
                task: refreshTask,
                modelContainer: modelContainer
            )
        }
        print("[BackgroundTaskManager] Registered background refresh handler")
    }
    
    /// Schedules the next background refresh.
    /// Should be called when the app enters the background.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: AppConstants.BackgroundTasks.playlistRefreshIdentifier
        )
        let intervalMinutes = UserDefaults.standard.integer(forKey: "syncIntervalMinutes")
        let minutes = intervalMinutes > 0 ? intervalMinutes : AppConstants.Sync.defaultSyncIntervalMinutes
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: TimeInterval(minutes * 60)
        )
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundTaskManager] Scheduled next refresh in \(minutes) minutes")
        } catch {
            print("[BackgroundTaskManager] Failed to schedule background refresh: \(error)")
        }
    }
    
    // MARK: - Private
    
    private static func handleAppRefresh(
        task: BGAppRefreshTask,
        modelContainer: ModelContainer
    ) {
        scheduleBackgroundRefresh()
        
        print("[BackgroundTaskManager] Background refresh triggered")

        let expired = OSAllocatedUnfairLock(initialState: false)

        let syncTask = Task { @Sendable in
            let appleMusicManager = AppleMusicManager()
            let spotifyClient = SpotifyAPIClient()

            let engine = SyncEngine(
                modelContainer: modelContainer,
                spotifyClient: spotifyClient,
                appleMusicManager: appleMusicManager
            )

            let results = await engine.handleBackgroundRefresh()
            let wasExpired = expired.withLock { $0 }
            let allSucceeded = !wasExpired && results.allSatisfy { $0.status != .failed }

            if !wasExpired && !allSucceeded {
                NotificationManager.postSyncFailureNotification(results: results)
            }

            print("[BackgroundTaskManager] Background sync completed, success: \(allSucceeded)")
            task.setTaskCompleted(success: allSucceeded)
        }

        task.expirationHandler = {
            print("[BackgroundTaskManager] Background task expired, cancelling sync")
            expired.withLock { $0 = true }
            syncTask.cancel()
        }
    }
}
