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
        modelContainer = SharedModelContainer.container

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
                // A background token-refresh failure may have cleared the
                // Keychain — re-sync the observable auth state with reality.
                spotifyAuth.refreshAuthStatus()
            case .background:
                BackgroundTaskManager.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}
