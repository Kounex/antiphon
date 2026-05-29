import Foundation
@preconcurrency import BackgroundTasks
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
            handleAppRefresh(
                task: task as! BGAppRefreshTask,
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
        
        let syncTask = Task { @Sendable in
            let appleMusicManager = AppleMusicManager()
            let spotifyClient = SpotifyAPIClient()
            
            let engine = SyncEngine(
                modelContainer: modelContainer,
                spotifyClient: spotifyClient,
                appleMusicManager: appleMusicManager
            )
            
            let results = await engine.handleBackgroundRefresh()
            let allSucceeded = results.allSatisfy { $0.status != .failed }
            
            if !allSucceeded {
                NotificationManager.postSyncFailureNotification(results: results)
            }
            
            print("[BackgroundTaskManager] Background sync completed, success: \(allSucceeded)")
            task.setTaskCompleted(success: allSucceeded)
        }
        
        task.expirationHandler = {
            print("[BackgroundTaskManager] Background task expired, cancelling sync")
            syncTask.cancel()
        }
    }
}
