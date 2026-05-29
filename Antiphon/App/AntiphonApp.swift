import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct AntiphonApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let spotifyAuth: SpotifyAuthManager
    let syncCoordinator: SyncCoordinator

    init() {
        // Initialize SwiftData with all model types
        do {
            modelContainer = try ModelContainer(
                for: SyncPair.self, CachedTrack.self, SyncLog.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Initialize auth managers
        spotifyAuth = SpotifyAuthManager()
        syncCoordinator = SyncCoordinator(modelContainer: modelContainer)

        // Register background tasks (handler creates its own auth instances)
        BackgroundTaskManager.registerTasks(modelContainer: modelContainer)
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(spotifyAuth)
                .environment(syncCoordinator)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                NotificationManager.requestPermissionIfNeeded()
            case .background:
                BackgroundTaskManager.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}
