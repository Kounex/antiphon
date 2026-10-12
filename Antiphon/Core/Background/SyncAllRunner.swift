import Foundation
import SwiftData
import UIKit

/// The widget's Sync all, run in the app's process by `SyncAllIntent`: every
/// seam that has synced before, now, under the background rules (strong
/// matches added, close matches to Review, removals by each seam's policy).
enum SyncAllRunner {
    @discardableResult
    static func run(modelContainer: ModelContainer = SharedModelContainer.container,
                    preferences: AppPreferences = .shared) async -> [SyncResult] {
        // Ask iOS for time to finish if the person leaves while it runs.
        let background = await BackgroundTime("Sync all")
        defer { Task { @MainActor in background.end() } }
        let engine = SyncEngine(modelContainer: modelContainer, spotifyClient: SpotifyAPIClient(),
                                appleMusicManager: AppleMusicManager())
        let seams = (try? await SwiftDataSeamRepository(modelContainer: modelContainer).seams()) ?? []
        // A widget tap has no other feedback: the Live Activity starts at once.
        let live = await SyncLiveActivity(startedAt: .distantPast)
        await live.show(.init(seamName: "Sync all", phase: "Checking your seams", done: 0,
                              total: max(seams.count - SyncAllScope.waiting(seams), 1)))
        let results = await engine.syncAllMonitored(trigger: .widget, preferences: preferences, everySeam: true) { seamId, progress in
            await live.show(seam: seams.first { $0.id == seamId }, progress: progress)
        }
        await live.finish(SyncActivityContent.finishedAll(results, waiting: SyncAllScope.waiting(seams)))
        if results.contains(where: { $0.status == .failed }), preferences.notifyBreaks {
            NotificationManager.postSyncFailureNotification(results: results)
        }
        await WidgetSnapshotWriter.refresh(modelContainer: modelContainer)
        return results
    }
}
