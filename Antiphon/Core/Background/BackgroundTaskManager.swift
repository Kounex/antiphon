import Foundation
@preconcurrency import BackgroundTasks
import SwiftData

/// Manages background task registration and scheduling for playlist sync.
/// Uses SyncCoordinator for sync operations so background syncs are visible
/// in the UI if the app is foregrounded during execution.
enum BackgroundTaskManager {
    
    /// Registers the background refresh task handler.
    /// Must be called before the app finishes launching.
    static func registerTasks(
        modelContainer: ModelContainer,
        spotifyAuth: SpotifyAuthManager
    ) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConstants.BackgroundTasks.playlistRefreshIdentifier,
            using: nil
        ) { task in
            handleAppRefresh(
                task: task as! BGAppRefreshTask,
                modelContainer: modelContainer,
                spotifyAuth: spotifyAuth
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
        modelContainer: ModelContainer,
        spotifyAuth: SpotifyAuthManager
    ) {
        // Always reschedule for next time
        scheduleBackgroundRefresh()
        
        print("[BackgroundTaskManager] Background refresh triggered")
        
        let syncTask = Task { @Sendable in
            let appleMusicManager = AppleMusicManager()
            let spotifyClient = SpotifyAPIClient(authManager: spotifyAuth)
            
            let engine = SyncEngine(
                modelContainer: modelContainer,
                spotifyClient: spotifyClient,
                appleMusicManager: appleMusicManager
            )
            
            let success = await engine.handleBackgroundRefresh()
            print("[BackgroundTaskManager] Background sync completed, success: \(success)")
            task.setTaskCompleted(success: success)
        }
        
        // Handle expiration — iOS is reclaiming our time
        task.expirationHandler = {
            print("[BackgroundTaskManager] Background task expired, cancelling sync")
            syncTask.cancel()
        }
    }
}
