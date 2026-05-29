import Foundation
import UserNotifications

/// Manages local notification permissions and delivery for background sync events.
///
/// Uses `UNUserNotificationCenter` to alert the user when monitored syncs fail
/// in the background. All methods are static since the notification center is
/// a singleton and no shared mutable state is needed.
enum NotificationManager {
    
    // MARK: - Permission
    
    /// Requests notification permission. Safe to call multiple times —
    /// the system dialog only appears once.
    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    print("[Notifications] Permission request failed: \(error.localizedDescription)")
                } else {
                    print("[Notifications] Permission granted: \(granted)")
                }
            }
        }
    }
    
    // MARK: - Sync Failure Notifications
    
    /// Posts a local notification summarising failed background syncs.
    /// Groups multiple failures into a single notification to avoid spam.
    static func postSyncFailureNotification(results: [SyncResult]) {
        let failures = results.filter { $0.status == .failed }
        guard !failures.isEmpty else { return }
        
        let content = UNMutableNotificationContent()
        content.sound = .default
        
        if failures.count == 1, let failure = failures.first {
            content.title = "Playlist Sync Failed"
            content.body = failure.message ?? "A monitored playlist failed to sync. Open Antiphon to review."
        } else {
            content.title = "\(failures.count) Playlist Syncs Failed"
            let messages = failures.compactMap(\.message)
            if let first = messages.first {
                content.body = "\(first)\(messages.count > 1 ? " (+\(messages.count - 1) more)" : "")"
            } else {
                content.body = "Multiple monitored playlists failed to sync. Open Antiphon to review."
            }
        }
        
        content.categoryIdentifier = "SYNC_FAILURE"
        content.threadIdentifier = "sync-failures"
        
        let request = UNNotificationRequest(
            identifier: "sync-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Notifications] Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}
