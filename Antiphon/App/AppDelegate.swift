import UIKit
import UserNotifications

/// Registers the question notifications' buttons and answers them in the
/// background, without opening the app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(QuestionCategory.allCases.map(\.notificationCategory)))
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        print("[Notifications] received \(response.actionIdentifier)")
        guard let action = QuestionAction(rawValue: response.actionIdentifier) else { return }
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        var container = SharedModelContainer.container
        #if DEBUG
        // The `ask` self-test answers against its own throwaway store.
        if info["selftest"] != nil, let store = SelfTestStore.container.withLock({ $0 }) { container = store }
        #endif
        let answer = await QuestionNotifications.answer(
            action, userInfo: info,
            review: SwiftDataSeamRepository(modelContainer: container),
            sync: LiveSyncService(modelContainer: container)
        )
        print("[Notifications] \(action.rawValue) → \(answer)")
        // iOS may suspend the app as soon as this returns: finish the widgets first.
        await WidgetSnapshotWriter.refresh(modelContainer: container)
        guard answer == .failed else { return }
        // Say so rather than fail quietly; the question is still in Review.
        let content = UNMutableNotificationContent()
        content.title = "Antiphon couldn't change the playlist"
        content.body = "The question is still waiting in Review. Open Antiphon to try again."
        try? await center.add(UNNotificationRequest(identifier: "answer-failed-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// Notifications also show while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
