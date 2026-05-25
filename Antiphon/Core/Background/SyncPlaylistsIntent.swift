import AppIntents
import SwiftData

/// App Intent that exposes playlist sync to the iOS Shortcuts app.
///
/// Users can trigger this via:
/// - Siri voice commands
/// - Shortcuts Automations (e.g., "Every day at 8 AM", "When I close Spotify")
/// - Manual shortcut execution
///
/// The intent runs silently in the background without opening the app.
struct SyncPlaylistsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Playlists"
    static let description = IntentDescription(
        "Synchronizes all monitored playlists between Spotify and Apple Music."
    )
    static let openAppWhenRun: Bool = false
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Create a fresh ModelContainer for this background execution
        let container = try ModelContainer(
            for: SyncPair.self, CachedTrack.self, SyncLog.self
        )
        
        let context = ModelContext(container)
        
        // Count monitored pairs
        let descriptor = FetchDescriptor<SyncPair>(
            predicate: #Predicate { $0.isMonitored == true }
        )
        
        let monitoredPairs = try context.fetch(descriptor)
        
        guard !monitoredPairs.isEmpty else {
            return .result(dialog: "No monitored playlists to sync.")
        }
        
        // Initialize managers
        let spotifyAuth = SpotifyAuthManager()
        let spotifyClient = SpotifyAPIClient(authManager: spotifyAuth)
        let appleMusicManager = AppleMusicManager()
        
        let syncEngine = SyncEngine(
            modelContainer: container,
            spotifyClient: spotifyClient,
            appleMusicManager: appleMusicManager
        )
        
        let results = await syncEngine.syncAllMonitored()
        
        let successCount = results.filter(\.isSuccess).count
        let totalAdded = results.reduce(0) { $0 + $1.tracksAdded }
        
        if totalAdded > 0 {
            return .result(dialog: "Synced \(successCount)/\(results.count) playlists. \(totalAdded) tracks added.")
        } else {
            return .result(dialog: "All \(successCount) playlists are up to date.")
        }
    }
}

// MARK: - App Shortcuts Provider

/// Makes the sync intent discoverable in the Shortcuts app
/// and via Siri suggestions.
struct AntiphonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncPlaylistsIntent(),
            phrases: [
                "Sync playlists in \(.applicationName)",
                "Update my playlists in \(.applicationName)",
                "Sync music in \(.applicationName)"
            ],
            shortTitle: "Sync Playlists",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
