import Foundation
import SwiftData
import UIKit

/// After a sync was stopped mid-write (iOS ended the app), some tracks are
/// left "syncing". At launch no sync can be running yet, so they go back to
/// pending; the next sync checks the playlist and adds only what didn't land.
enum SyncRecovery {
    @discardableResult
    static func resetInterrupted(in container: ModelContainer) -> Int {
        let context = ModelContext(container)
        // Enum comparisons don't translate to SwiftData predicates: filter in memory.
        let stuck = ((try? context.fetch(FetchDescriptor<CachedTrack>())) ?? []).filter { $0.syncState == .syncing }
        guard !stuck.isEmpty else { return 0 }
        for track in stuck { track.syncState = .pending }
        try? context.save()
        return stuck.count
    }
}

/// The ordinary few seconds iOS gives a backgrounded app to finish. Handed back
/// when done or when the time runs out: an app that holds it past its time
/// is ended by iOS.
@MainActor
final class BackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Called on the main thread when time is up.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
