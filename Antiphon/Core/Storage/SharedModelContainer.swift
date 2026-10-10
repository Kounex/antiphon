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
    /// Every persisted model. New fields and models are additive, so stores
    /// written by earlier versions open through SwiftData's automatic
    /// lightweight migration (covered by `SchemaMigrationTests`).
    static let models: [any PersistentModel.Type] = [
        SyncPair.self, CachedTrack.self, SyncLog.self, SyncChange.self, SyncProblem.self
    ]

    static let container: ModelContainer = {
        do {
            return try make()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    /// Builds a container on the default store, or on `url` (tests, previews).
    static func make(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let configuration = if let url {
            ModelConfiguration(url: url)
        } else {
            ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: Schema(models), configurations: configuration)
    }
}
