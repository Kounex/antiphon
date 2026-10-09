import Foundation
import SwiftData

/// The single process-wide SwiftData stack for Antiphon.
///
/// The app, `BGAppRefreshTask` handlers, and App Intents (Shortcuts/Siri) all
/// operate on the same persistent store. Giving each entry point its own
/// `ModelContainer` on that store risks concurrent write conflicts (e.g. a
/// Shortcut automation running while a foreground sync is mid-write), so every
/// entry point must share this one container.
enum SharedModelContainer {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: SyncPair.self, CachedTrack.self, SyncLog.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()
}
